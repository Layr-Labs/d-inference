import CoreImage
import CryptoKit
import DarkbloomClusterProtocol
import Foundation
import ImageIO
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// GLM images and video on the tensor-parallel pair: the ranks' half of
/// `ClusterGLMMedia` (the leader's is `DistributedGLMMediaIngress`), one per
/// request, solo or in a lane.
///
/// Rank 0, from its reservation on (`startPreparation`), off the executor and
/// with no MLX array: rebuilds from the encoded bytes the media values the
/// product's ingest builds (`MediaIngest`: the full first image with its
/// orientation, a memory-backed video asset), prepares them with the SDK's
/// `GLM5NextProcessor.prepareMediaValues` (the media half of
/// `prepareDetailed`, the leader's call) and requires every grid and patch
/// digest to equal the leader's. A lane joins only once this ended
/// (`preparationFinished`), so the other lanes never wait for it.
///
/// Both ranks, when the request opens (`open`), in lockstep: small sums that
/// carry rank 0's preparation status and each rank's stop (cancel or
/// deadline) until the preparation ended or a rank stopped, so both ranks act
/// on the same outcome (a stop: no feature is made; a failed or different
/// preparation: an agreement failure on both ranks); then, per temporal pair,
/// rank 0 runs the vision tower with the
/// product's limits for that frame, as `buildGLM5NextSubmission` does (default
/// GPU stream, `.automatic` attention: fused for the tower's head width), and
/// one sealed all-sum carries the features to rank 1, which adds negative zero
/// (`x + -0 == x` for every value, signed zeros included, and the sum rounds
/// once); a last small sum carries rank 0's bit-for-bit check of every frame.
/// Every sum is evaluated by itself, so no other collective can be ordered
/// differently around it on one rank, and no wait inside one lasts longer
/// than one frame's tower. Nothing inside `open` throws on one rank alone
/// except a native failure (which ends the pair, as anywhere in a request). A prefill chunk holding media positions replaces
/// their embedding rows with the features, as the product's
/// `spliceEmbeddings` does, and the NextN history is primed with the same rows
/// (a media position's next input is its feature row, as a multimodal
/// target's drafter is fed); every other row and chunk is the text path's.
final class GLM5NextTensorParallelMedia {
    let media: ClusterGLMMedia
    /// Every frame, sorted by its prompt position (the splice order).
    let positioned: [ClusterGLMMedia.Frame]
    let hiddenSize: Int
    /// Values per patch: channels x temporal patch x patch x patch.
    let patchWidth: Int
    let dtype: DType
    /// Both ranks: each frame's agreed features in tower order, from `open`.
    private(set) var shared: [MLXArray] = []
    /// Rank 0: the preparation's task and outcome.
    let preparation = GLM5NextMediaPreparation()

    init(media: ClusterGLMMedia, prompt: [Int], configuration c: GLM5NextConfiguration) throws {
        try media.validate(prompt: prompt, imageToken: c.imageTokenId, startToken: c.imageStartTokenId,
            endToken: c.imageEndTokenId, videoToken: c.videoTokenId)
        guard c.textConfig.dtype == "bfloat16", c.visionConfig.outHiddenSize == c.textConfig.hiddenSize,
              media.processor.patchSize == c.visionConfig.patchSize else {
            throw ProbeError("GLM tensor-parallel media differs from the loaded model's widths or patches")
        }
        self.media = media
        positioned = media.frames.sorted { $0.tokenOffset < $1.tokenOffset }
        hiddenSize = c.textConfig.hiddenSize
        let v = c.visionConfig
        patchWidth = v.inChannels * v.temporalPatchSize * v.patchSize * v.patchSize
        dtype = .bfloat16
    }

    var featureCount: Int { media.featureTokens }

    // MARK: - Memory

    /// Bytes this request adds to a rank's reservation. Rank 0: the encoded
    /// bytes (held, and their media asset), the processor's decoded-frame cap,
    /// the prepared patches twice (host values and their array), the tower's
    /// working set for the largest frame and the features twice (its own and
    /// the agreed copy). Rank 1: the agreed features and one frame's operand.
    static func requestBytes(_ media: ClusterGLMMedia, rank: Int, configuration c: GLM5NextConfiguration,
                             maximumDecodedBytes: Int = defaultProcessorBytes) throws -> Int {
        typealias Bytes = QwenLongPrefillCheckedBytes
        let v = c.visionConfig
        let patchWidth = v.inChannels * v.temporalPatchSize * v.patchSize * v.patchSize
        // The processor never prepares more (`maximumPreparedBytes`): beyond
        // it the product refuses the request, and so does the pair.
        guard media.preparedBytes(patchWidth: patchWidth) <= maximumDecodedBytes else {
            throw ProbeError("GLM media prepares more patches than the processor admits")
        }
        let features = try Bytes.product([media.featureTokens, c.textConfig.hiddenSize, 2])
        let frame = try Bytes.product([media.largestFramePatches / 4, c.textConfig.hiddenSize, 2])
        guard rank == 0 else { return try Bytes.sum([features, frame, frame]) }
        return try Bytes.sum([
            Bytes.product([media.encodedBytes, 2]), maximumDecodedBytes,
            Bytes.product([media.preparedBytes(patchWidth: patchWidth), 2]),
            towerWorkingSetBytes(v, patches: media.largestFramePatches),
            Bytes.product([features, 2]), frame,
        ])
    }

    /// The most any one media request adds on `rank` (its readiness
    /// capacity): the processor's prepared-bytes cap bounds its patches, so
    /// its features (a quarter of them), whatever the context.
    static func capacityBytes(rank: Int, configuration c: GLM5NextConfiguration) throws -> Int {
        typealias Bytes = QwenLongPrefillCheckedBytes
        let v = c.visionConfig
        let patchBytes = try Bytes.product([v.inChannels, v.temporalPatchSize, v.patchSize, v.patchSize, 4])
        let features = try Bytes.product([defaultProcessorBytes / max(1, patchBytes) / 4, c.textConfig.hiddenSize, 2])
        let frame = try Bytes.product([ClusterGLMMedia.maximumFramePatches / 4, c.textConfig.hiddenSize, 2])
        guard rank == 0 else { return try Bytes.sum([features, frame, frame]) }
        return try Bytes.sum([
            Bytes.product([ClusterGLMMedia.maximumEncodedBytes, 2]), defaultProcessorBytes,
            Bytes.product([defaultProcessorBytes, 2]),
            towerWorkingSetBytes(c.visionConfig, patches: ClusterGLMMedia.maximumFramePatches),
            Bytes.product([features, 2]), frame,
        ])
    }

    /// `GLM5NextProcessorConfiguration`'s decoded and prepared byte caps.
    static let defaultProcessorBytes = 512 * 1024 * 1024

    /// Float32 values live while the tower runs one frame of `patches`
    /// patches: input, residual stream, attention (QKV, head-major copies, one
    /// score and one probability tile, output), the MLP and the merger. The
    /// product prices its media reservation the same way.
    static func towerWorkingSetBytes(_ c: GLM5NextVisionConfiguration, patches: Int, queryTile: Int = 128) throws -> Int {
        let n = max(0, patches), merged = n / 4
        let elements = [
            n * c.inChannels * c.temporalPatchSize * c.patchSize * c.patchSize,
            2 * n * c.hiddenSize, 6 * n * c.hiddenSize,
            2 * c.numHeads * min(queryTile, n) * n,
            2 * n * c.hiddenSize, 3 * n * c.intermediateSize,
            3 * merged * c.projectionIntermediateSize, 2 * merged * c.outHiddenSize,
        ]
        return try QwenLongPrefillCheckedBytes.product([QwenLongPrefillCheckedBytes.sum(elements), 4])
    }

    // MARK: - Rank 0: patches, off the executor

    /// Rank 0 at reservation: starts the preparation on its own task and
    /// returns. Host work only (image and video decoding, resize, patchify,
    /// digests); its outcome waits for `open`.
    func startPreparation() {
        let media = self.media, patchWidth = self.patchWidth
        startPreparation {
            try media.verifyEncodedBytes()
            let p = media.processor
            let processor = GLM5NextProcessor(imageConfiguration: try GLM5NextProcessorConfiguration(
                patchSize: p.patchSize, imageMinimumTokens: p.imageMinimumTokens, imageMaximumTokens: p.imageMaximumTokens,
                videoMinimumTokens: p.videoMinimumTokens, videoMaximumTokens: p.videoMaximumTokens))
            var images: [UserInput.Image] = [], videos: [UserInput.Video] = []
            for item in media.items {
                guard let data = item.encoded else { throw ProbeError("GLM media bytes are missing") }
                switch item.kind {
                case .image: images.append(try Self.image(data))
                case .video: videos.append(.memoryBacked(try MemoryBackedVideoAsset(videoData: data)))
                }
            }
            let prepared = try await processor.prepareMediaValues(images: images, videos: videos)
            let items = prepared.images + prepared.videos
            guard items.count == media.items.count else { throw ProbeError("GLM media preparation lost an item") }
            for (described, item) in zip(media.items, items) {
                guard item.grid.temporal == described.temporal, item.grid.height == described.height,
                      item.grid.width == described.width,
                      item.values.count == described.temporal * described.height * described.width * patchWidth,
                      Self.digest(item.values) == described.patchesSHA256 else {
                    throw ProbeError("GLM media patches differ from the leader's")
                }
            }
            return items.map(\.values)
        }
    }

    /// `startPreparation` with another body (tests: a preparation that ends
    /// when they say, or fails).
    func startPreparation(_ body: @escaping @Sendable () async throws -> [[Float]]) {
        preparation.start(body)
    }

    /// Rank 0's lane joins once this is true: its preparation ended, or its
    /// owner cancelled it (it then opens and leaves without features). True on
    /// rank 1, which prepares nothing and joins what rank 0 names.
    var joinable: Bool { preparation.joinable }

    /// Stops a preparation nobody will open (withdrawn or cancelled).
    func cancelPreparation() { preparation.cancel() }

    // MARK: - Both ranks: the request opens

    /// Both ranks, in lockstep, when the request opens. True once every
    /// frame's features are agreed (`shared`); false when either rank stopped
    /// first (`stop`: its cancel or deadline, read only between sums), on
    /// both ranks, with no feature made. A failed or different preparation
    /// throws on both ranks (an agreement failure). `sum` is the sealed
    /// all-sum; rank 1 passes no tower.
    func open(rank: Int, tower: GLM5NextVisionTower?, sum: (MLXArray) -> MLXArray, stop: () -> Bool) throws -> Bool {
        guard shared.isEmpty else { throw ProbeError("GLM media opened twice") }
        // 1. Rank 0's preparation status and both ranks' stops.
        let outcome = try Self.agreeOutcome(rank: rank, status: { preparation.status }, stop: stop) { words in
            let agreed = sum(MLXArray(words))
            try MLX.withError { errors in eval(agreed); try errors.check() }
            return agreed.asArray(Float.self)
        }
        guard let status = outcome else {
            if rank == 0 { log("darkbloom-tensor-parallel-media-v1 rank=0 opened=0 stopped=1") }
            return false
        }
        guard status == 1 else {
            throw ProbeError("GLM media preparation failed or differs from the leader's"
                + (rank == 0 ? " (\(preparation.failure))" : ""))
        }
        // 2. Per temporal pair: rank 0's tower, then the sum that carries it.
        var changed: Float = 0
        let values = rank == 0 ? preparation.take() : nil
        let started = DispatchTime.now().uptimeNanoseconds
        try MLX.withError { errors in
            // Native errors only: a stop is not read inside the sums' sequence.
            func checked() throws { try errors.check() }
            if rank == 0 {
                // `.automatic` attention fuses only on the default GPU stream, as
                // on the product's request path; refuse rather than tile here.
                guard tower != nil, Device.defaultDevice().deviceType == .gpu, StreamOrDevice.default.stream == Stream.gpu,
                      let values, values.count == media.items.count else {
                    throw ProbeError("GLM media tower must run on the default GPU stream with its patches")
                }
            }
            for (index, item) in media.items.enumerated() {
                let rows = item.height * item.width
                var patches: MLXArray?
                if rank == 0, let values {
                    patches = MLXArray(values[index]).reshaped(item.temporal * rows, patchWidth)
                }
                let limits = GLM5NextVisionLimits(maximumPatches: item.maximumPatches,
                    maximumFramePatches: item.maximumPatches, maximumQueryTokens: item.maximumQueryTokens,
                    maximumScoreElements: item.maximumScoreElements)
                let grid = try GLM5NextVisionGrid(temporal: 1, height: item.height, width: item.width)
                for pair in 0 ..< item.temporal {
                    var local: MLXArray?
                    if rank == 0, let tower, let patches {
                        let value = try tower.forward(patches: patches[(pair * rows) ..< ((pair + 1) * rows)],
                            grids: [grid], limits: limits, checkpoint: { _ in try checked() })
                        eval(value)
                        try checked()
                        guard value.shape == [item.tokensPerFrame, hiddenSize], value.dtype == dtype else {
                            throw ProbeError("GLM media features differ from their span or dtype")
                        }
                        local = value
                    }
                    let operand = local ?? Self.negativeZeros([item.tokensPerFrame, hiddenSize], dtype: dtype)
                    let agreed = sum(operand)
                    eval(agreed)
                    try errors.check()
                    if let local, changed == 0, !(agreed.shape == local.shape && agreed.dtype == dtype
                        && all(view(agreed, dtype: .uint16) .== view(local, dtype: .uint16)).item(Bool.self)) {
                        changed = 1
                    }
                    try errors.check()
                    shared.append(agreed)
                }
            }
            // 3. Rank 0's verdict on every frame, so both ranks end together.
            let verdict = sum(MLXArray([rank == 0 ? changed : 0]))
            eval(verdict)
            try errors.check()
            changed = verdict.item(Float.self)
        }
        guard changed == 0, shared.count == media.frames.count,
              zip(shared, media.frames).allSatisfy({ $0.shape == [$1.tokenCount, hiddenSize] && $0.dtype == dtype }) else {
            shared = []
            throw ProbeError("GLM media features changed crossing the link")
        }
        if rank == 0 {
            log("darkbloom-tensor-parallel-media-v1 rank=0 items=\(media.items.count) frames=\(media.frames.count)"
                + " tokens=\(featureCount) prepare_ns=\(preparation.elapsed) tower_ns=\(DispatchTime.now().uptimeNanoseconds - started)")
        }
        return true
    }

    /// Step 1 of `open`, its arithmetic aside: one small sum a round of
    /// [rank 0's preparation status (0 preparing, 1 prepared, 2 failed), rank
    /// 0's stop, rank 1's stop] until a rank stopped (nil) or the preparation
    /// ended (its status). Both ranks see the same sums, so they return the
    /// same outcome after the same number of rounds.
    static func agreeOutcome(rank: Int, status: () -> Float, stop: () -> Bool,
                             exchange: ([Float]) throws -> [Float]) throws -> Float? {
        while true {
            let stopped: Float = stop() ? 1 : 0
            let words = try exchange(rank == 0 ? [status(), stopped, 0] : [0, 0, stopped])
            guard words.count == 3 else { throw ProbeError("GLM media status has a wrong shape") }
            if words[1] + words[2] > 0 { return nil }
            if words[0] != 0 { return words[0] }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// The additive identity that keeps every value's bits, signed zeros
    /// included: -0 (+0 would turn a -0 feature into +0).
    static func negativeZeros(_ shape: [Int], dtype: DType) -> MLXArray {
        -MLXArray.zeros(shape, dtype: dtype)
    }

    // MARK: - Prefill

    /// The chunk's input embeddings `[1, end - start, hidden]` with every media
    /// row replaced by its feature row; nil when the chunk holds none (it then
    /// runs the text path unchanged).
    func embeddings(tokens: MLXArray, from start: Int, to end: Int, embedding: (MLXArray) -> MLXArray) throws -> MLXArray? {
        guard shared.count == media.frames.count else { throw ProbeError("GLM media features never crossed") }
        let index = Dictionary(uniqueKeysWithValues: media.frames.enumerated().map { ($0.element.tokenOffset, $0.offset) })
        var pieces: [(Range<Int>, MLXArray)] = []
        for frame in positioned {
            let lo = max(frame.tokenOffset, start), hi = min(frame.tokenOffset + frame.tokenCount, end)
            guard lo < hi, let k = index[frame.tokenOffset] else { continue }
            pieces.append((lo ..< hi, shared[k][(lo - frame.tokenOffset) ..< (hi - frame.tokenOffset)]))
        }
        guard !pieces.isEmpty else { return nil }
        return Self.splice(text: embedding(tokens), start: start, rows: pieces)
    }

    /// The product's splice (`CBv2MultimodalResolver.spliceEmbeddings`): text
    /// rows and media rows interleaved by concatenation, media cast to the text
    /// embedding's dtype. `rows` are disjoint, sorted and inside the chunk.
    static func splice(text: MLXArray, start: Int, rows: [(Range<Int>, MLXArray)]) -> MLXArray {
        let length = text.dim(1)
        var segments: [MLXArray] = []
        var cursor = 0
        for (range, value) in rows {
            let lo = range.lowerBound - start, hi = range.upperBound - start
            if lo > cursor { segments.append(text[0..., cursor ..< lo, 0...]) }
            segments.append(value.expandedDimensions(axis: 0).asType(text.dtype))
            cursor = hi
        }
        if cursor < length { segments.append(text[0..., cursor ..< length, 0...]) }
        return segments.count == 1 ? segments[0] : concatenated(segments, axis: 1)
    }

    // MARK: - Decoding as the product's ingest does

    /// `MediaIngest.decodeImageData`: the full image at index 0 (never an EXIF
    /// thumbnail) with the file's orientation applied, origin at zero.
    static func image(_ data: Data) throws -> UserInput.Image {
        let image: CIImage
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: true] as CFDictionary),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) {
            var decoded = CIImage(cgImage: cgImage)
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let raw = properties[kCGImagePropertyOrientation] as? UInt32,
               let orientation = CGImagePropertyOrientation(rawValue: raw) {
                decoded = decoded.oriented(orientation)
            }
            image = normalizedExtent(decoded)
        } else if let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            image = normalizedExtent(decoded)
        } else {
            throw ProbeError("GLM media image does not decode")
        }
        return .ciImage(image)
    }

    private static func normalizedExtent(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// SHA-256 of float32 values' bytes (an array's row-major bytes).
    static func digest(_ values: [Float]) -> String {
        values.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}

/// Rank 0's media preparation: one task, its outcome under a lock. Host work
/// only; the patches stay host values until `open` makes them arrays.
final class GLM5NextMediaPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var result: [[Float]]?
    private var error: String?
    private var done = false
    private var cancelled = false
    private var started: UInt64 = 0
    private var ended: UInt64 = 0

    func start(_ body: @escaping @Sendable () async throws -> [[Float]]) {
        lock.withLock {
            guard task == nil else { return }
            started = DispatchTime.now().uptimeNanoseconds
            task = Task.detached { [self] in
                do {
                    let values = try await body()
                    lock.withLock { result = values; done = true; ended = DispatchTime.now().uptimeNanoseconds }
                } catch {
                    let text = String(describing: error)
                    lock.withLock { self.error = text; done = true; ended = DispatchTime.now().uptimeNanoseconds }
                }
            }
        }
    }
    var finished: Bool { lock.withLock { done } }
    /// 0 while it runs, 1 prepared, 2 failed (its words in `open`'s status sum).
    var status: Float { lock.withLock { done ? (result != nil ? 1 : 2) : 0 } }
    /// Never started (rank 1), ended, or cancelled.
    var joinable: Bool { lock.withLock { task == nil || done || cancelled } }
    var failure: String { lock.withLock { error.map { String($0.prefix(160)) } ?? "none" } }
    var elapsed: UInt64 { lock.withLock { ended >= started ? ended - started : 0 } }
    /// Hands the values over once (they then live as the tower's arrays).
    func take() -> [[Float]]? { lock.withLock { defer { result = nil }; return result } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
}
