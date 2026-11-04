import Foundation
import CryptoKit

/// GLM-5.3-Flash image and video input for the tensor-parallel pair
/// (`contract`). The leader renders and expands the prompt exactly as the
/// single-Mac product does (its media decode, processor and prompt expansion)
/// and describes every media part here: its encoded bytes' digest, the
/// processor's grid, the causal token span of each temporal pair, the tower
/// limits the product uses for that frame, and the digest of the prepared
/// patches. Rank 0 receives the encoded bytes as well (from the leader on its
/// own Mac), prepares the same patches, requires the same digests and runs the
/// vision tower; rank 1 receives digests only. No pixels, tensors or URLs cross
/// this boundary, and no caller-provided embedding is ever accepted.
public struct ClusterGLMMedia: Equatable, Sendable {
    public static let contract = "glm53_tp_media_v1"
    /// The single-Mac ingest caps (`MediaIngest`): images and videos per request.
    public static let maximumImages = 16
    public static let maximumVideos = 8
    /// Encoded bytes of every part together. A request reaches the provider in
    /// at most 32 MiB (coordinator frame, local upload), base64 included.
    public static let maximumEncodedBytes = 32 * 1024 * 1024
    /// The SDK tower's own per-frame patch ceiling (`GLM5NextVisionLimits`).
    public static let maximumFramePatches = 32_000
    /// Temporal pairs and images together: eight videos at 2 FPS over the
    /// 600 s duration cap (601 pairs each, the final one padded), and the images.
    public static let maximumFrames = maximumVideos * 601 + maximumImages
    /// The tower's query-tile and score-element ceilings (`GLM5NextVisionLimits`).
    public static let maximumQueryTokens = 128
    public static let maximumScoreElements = 32_000_000
    /// The envelope as the reservation carries it to rank 0: base64 bytes plus
    /// bounded metadata.
    public static let maximumEnvelopeBytes = (maximumEncodedBytes + 2) / 3 * 4 + 1024 * 1024

    public enum Kind: String, Sendable { case image, video }

    public struct Item: Equatable, Sendable {
        public let kind: Kind
        /// SHA-256 (lowercase hex) of the part's encoded bytes as decoded from its data URI.
        public let sha256: String
        public let byteCount: Int
        /// The encoded bytes: rank 0's reservation only.
        public let encoded: Data?
        /// The processor's grid in patches: temporal pairs, rows, columns.
        public let temporal, height, width: Int
        /// The single-Mac tower limits for one frame of this grid
        /// (`VisionTowerBudget.glm5FrameLimits`).
        public let maximumPatches, maximumQueryTokens, maximumScoreElements: Int
        /// SHA-256 of the item's prepared patches (row-major float32 bytes).
        public let patchesSHA256: String
        /// The first prompt position of each temporal pair's span, in pair order.
        public let tokenOffsets: [Int]
        /// Tokens per temporal pair: the merged patches of one frame.
        public var tokensPerFrame: Int { height * width / 4 }
        public init(kind: Kind, sha256: String, byteCount: Int, encoded: Data?, temporal: Int, height: Int, width: Int,
                    maximumPatches: Int, maximumQueryTokens: Int, maximumScoreElements: Int, patchesSHA256: String,
                    tokenOffsets: [Int]) {
            self.kind = kind; self.sha256 = sha256; self.byteCount = byteCount; self.encoded = encoded
            self.temporal = temporal; self.height = height; self.width = width
            self.maximumPatches = maximumPatches; self.maximumQueryTokens = maximumQueryTokens
            self.maximumScoreElements = maximumScoreElements; self.patchesSHA256 = patchesSHA256
            self.tokenOffsets = tokenOffsets
        }
        /// The same item without its bytes.
        public var withoutEncodedBytes: Item {
            .init(kind: kind, sha256: sha256, byteCount: byteCount, encoded: nil, temporal: temporal, height: height,
                width: width, maximumPatches: maximumPatches, maximumQueryTokens: maximumQueryTokens,
                maximumScoreElements: maximumScoreElements, patchesSHA256: patchesSHA256, tokenOffsets: tokenOffsets)
        }
    }

    /// One temporal pair (a still image is one), in the order the tower runs:
    /// every image, then every video, each pair in order.
    public struct Frame: Equatable, Sendable {
        public let item: Int
        public let pair: Int
        public let tokenOffset: Int
        public let tokenCount: Int
    }

    /// The single-Mac processor's token budgets (the artifact's
    /// processor_config.json), which rank 0's processor is built with.
    public struct Processor: Equatable, Sendable {
        public let patchSize, imageMinimumTokens, imageMaximumTokens, videoMinimumTokens, videoMaximumTokens: Int
        public init(patchSize: Int, imageMinimumTokens: Int, imageMaximumTokens: Int,
                    videoMinimumTokens: Int, videoMaximumTokens: Int) {
            self.patchSize = patchSize; self.imageMinimumTokens = imageMinimumTokens
            self.imageMaximumTokens = imageMaximumTokens; self.videoMinimumTokens = videoMinimumTokens
            self.videoMaximumTokens = videoMaximumTokens
        }
        var values: [Int] { [patchSize, imageMinimumTokens, imageMaximumTokens, videoMinimumTokens, videoMaximumTokens] }
        /// The processor's own bounds (`GLM5NextProcessorConfiguration`).
        var valid: Bool {
            (1...128).contains(patchSize) && imageMinimumTokens > 0 && imageMinimumTokens <= imageMaximumTokens
                && imageMaximumTokens <= 8000 && videoMinimumTokens > 0 && videoMinimumTokens <= videoMaximumTokens
                && videoMaximumTokens <= 240_000
        }
    }

    /// The model configuration's SHA-256: the loaded peers' identity.
    public let configurationSHA256: String
    public let processor: Processor
    /// Every image in prompt order, then every video in prompt order.
    public let items: [Item]

    public init(configurationSHA256: String, processor: Processor, items: [Item]) {
        self.configurationSHA256 = configurationSHA256; self.processor = processor; self.items = items
    }

    /// What rank 1 is sent: every digest, no bytes.
    public var withoutEncodedBytes: Self {
        .init(configurationSHA256: configurationSHA256, processor: processor, items: items.map(\.withoutEncodedBytes))
    }
    public var carriesEncodedBytes: Bool { items.contains { $0.encoded != nil } }
    public var encodedBytes: Int { items.reduce(0) { $0 + $1.byteCount } }
    public var frames: [Frame] {
        items.enumerated().flatMap { index, item in
            item.tokenOffsets.enumerated().map {
                Frame(item: index, pair: $0.offset, tokenOffset: $0.element, tokenCount: item.tokensPerFrame)
            }
        }
    }
    /// Prompt positions the media occupies.
    public var featureTokens: Int { items.reduce(0) { $0 + $1.temporal * $1.tokensPerFrame } }
    /// The largest one frame's patches (the tower's working set).
    public var largestFramePatches: Int { items.map { $0.height * $0.width }.max() ?? 0 }
    /// The prepared patches (float32), every item together.
    public func preparedBytes(patchWidth: Int) -> Int {
        items.reduce(0) { $0 + $1.temporal * $1.height * $1.width * patchWidth * 4 }
    }

    /// Structure only, as both ranks and the leader check it before anything is
    /// reserved: counts, digests, grids, limits and byte bounds. Bytes, when
    /// present, must have their declared length (rank 0 checks their digest).
    public func validateStructure() throws {
        try workerRequire(Self.hex(configurationSHA256) && processor.valid, "Invalid GLM media source identity or processor")
        let images = items.filter { $0.kind == .image }.count, videos = items.count - images
        try workerRequire(!items.isEmpty && images <= Self.maximumImages && videos <= Self.maximumVideos
            && items.prefix(images).allSatisfy({ $0.kind == .image }), "Invalid GLM media count or order")
        try workerRequire(!items.contains(where: { $0.encoded != nil }) || items.allSatisfy({ $0.encoded?.count == $0.byteCount }),
            "GLM media bytes are partial")
        var bytes = 0, frames = 0
        for item in items {
            try workerRequire(Self.hex(item.sha256) && Self.hex(item.patchesSHA256)
                && item.byteCount > 0 && item.byteCount <= Self.maximumEncodedBytes - bytes, "Invalid GLM media bytes")
            bytes += item.byteCount
            let patches = item.height.multipliedReportingOverflow(by: item.width)
            try workerRequire(item.temporal > 0 && (item.kind == .video || item.temporal == 1)
                && item.height > 0 && item.width > 0 && item.height.isMultiple(of: 2) && item.width.isMultiple(of: 2)
                && !patches.overflow && patches.partialValue <= Self.maximumFramePatches
                && item.tokenOffsets.count == item.temporal && item.temporal <= Self.maximumFrames - frames
                && item.tokenOffsets.allSatisfy({ (1...ClusterWorkerLimits.wirePromptTokens).contains($0) }),
                "Invalid GLM media grid")
            frames += item.temporal
            try workerRequire((patches.partialValue...Self.maximumFramePatches).contains(item.maximumPatches)
                && (1...min(Self.maximumQueryTokens, patches.partialValue)).contains(item.maximumQueryTokens)
                && (1...Self.maximumScoreElements).contains(item.maximumScoreElements), "Invalid GLM media tower limits")
        }
    }

    /// Structure, and every span bound to the prompt: each temporal pair's
    /// tokens are image markers between the begin and end image markers, spans
    /// are disjoint and in item and pair order per modality, every image marker
    /// in the prompt is owned, and no unexpanded video marker remains.
    public func validate(prompt: [Int], imageToken: Int, startToken: Int, endToken: Int, videoToken: Int) throws {
        try validateStructure()
        try workerRequire(featureTokens < prompt.count, "GLM media exceeds the prompt")
        var spans: [Range<Int>] = []
        for kind in [Kind.image, .video] {
            var last = 0
            for item in items where item.kind == kind {
                for offset in item.tokenOffsets {
                    let stop = offset + item.tokensPerFrame
                    try workerRequire(offset > last && offset >= 1 && stop < prompt.count
                        && prompt[offset - 1] == startToken && prompt[stop] == endToken
                        && prompt[offset..<stop].allSatisfy({ $0 == imageToken }), "Unbound GLM media span")
                    last = offset; spans.append(offset..<stop)
                }
            }
        }
        spans.sort { $0.lowerBound < $1.lowerBound }
        try workerRequire(zip(spans, spans.dropFirst()).allSatisfy { $0.upperBound < $1.lowerBound }, "Overlapping GLM media spans")
        try workerRequire(!prompt.contains(videoToken) && prompt.filter({ $0 == imageToken }).count == featureTokens,
            "Unowned GLM media marker")
    }

    /// Rank 0: the bytes it holds are the ones the leader described.
    public func verifyEncodedBytes() throws {
        for item in items {
            guard let data = item.encoded else { throw ClusterWorkerProtocolError.invalid("GLM media bytes are missing") }
            try workerRequire(data.count == item.byteCount && Self.sha256(data) == item.sha256, "GLM media bytes differ from their digest")
        }
    }

    /// Identity of everything both ranks act on (bytes through their digests),
    /// independent of JSON ordering and of whether the bytes are present.
    public var fingerprint: String {
        var hash = SHA256()
        hash.update(data: Data((Self.contract + "|" + configurationSHA256).utf8))
        func integer(_ value: Int) {
            var n = UInt64(bitPattern: Int64(value)).bigEndian
            withUnsafeBytes(of: &n) { hash.update(data: Data($0)) }
        }
        for n in processor.values { integer(n) }
        integer(items.count)
        for item in items {
            hash.update(data: Data((item.kind.rawValue + "|" + item.sha256 + "|" + item.patchesSHA256).utf8))
            for n in [item.byteCount, item.temporal, item.height, item.width, item.maximumPatches,
                      item.maximumQueryTokens, item.maximumScoreElements, item.tokenOffsets.count] { integer(n) }
            for offset in item.tokenOffsets { integer(offset) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // MARK: - Wire (inside the reservation)

    func wireObject() -> [String: Any] {
        ["configurationSHA256": configurationSHA256, "processor": processor.values, "items": items.map { item -> [String: Any] in
            var object: [String: Any] = ["kind": item.kind.rawValue, "sha256": item.sha256, "byteCount": item.byteCount,
                "temporal": item.temporal, "height": item.height, "width": item.width,
                "maximumPatches": item.maximumPatches, "maximumQueryTokens": item.maximumQueryTokens,
                "maximumScoreElements": item.maximumScoreElements, "patchesSHA256": item.patchesSHA256,
                "tokenOffsets": item.tokenOffsets]
            if let encoded = item.encoded { object["encoded"] = encoded.base64EncodedString() }
            return object
        }]
    }

    static func decode(wire object: [String: Any]) throws -> Self {
        var root = WorkerObject(object)
        let configuration = try root.string("configurationSHA256")
        let numbers = try root.ints("processor")
        try workerRequire(numbers.count == 5, "Invalid GLM media processor")
        let processor = Processor(patchSize: numbers[0], imageMinimumTokens: numbers[1], imageMaximumTokens: numbers[2],
            videoMinimumTokens: numbers[3], videoMaximumTokens: numbers[4])
        let objects = try root.objects("items"); try root.finish()
        try workerRequire((1...(maximumImages + maximumVideos)).contains(objects.count), "Invalid GLM media count")
        var remaining = maximumEncodedBytes
        let items = try objects.map { object -> Item in
            var r = WorkerObject(object)
            var encoded: Data?
            if r.values["encoded"] != nil {
                let text = try r.string("encoded")
                try workerRequire(text.utf8.count <= (remaining + 2) / 3 * 4, "GLM media base64 bound")
                guard let data = Data(base64Encoded: text), data.count <= remaining else {
                    throw ClusterWorkerProtocolError.invalid("Invalid GLM media encoding")
                }
                remaining -= data.count; encoded = data
            }
            let item = try Item(kind: r.enumeration("kind"), sha256: r.string("sha256"), byteCount: r.int("byteCount"),
                encoded: encoded, temporal: r.int("temporal"), height: r.int("height"), width: r.int("width"),
                maximumPatches: r.int("maximumPatches"), maximumQueryTokens: r.int("maximumQueryTokens"),
                maximumScoreElements: r.int("maximumScoreElements"), patchesSHA256: r.string("patchesSHA256"),
                tokenOffsets: r.ints("tokenOffsets"))
            try r.finish()
            return item
        }
        let value = Self(configurationSHA256: configuration, processor: processor, items: items)
        try value.validateStructure()
        return value
    }

    /// The envelope alone as bounded JSON (the provider's request payload
    /// between its ingress and its execution owner).
    public func encoded() throws -> Data {
        try validateStructure()
        let data = try JSONSerialization.data(withJSONObject: wireObject(), options: [.sortedKeys, .withoutEscapingSlashes])
        try workerRequire(data.count <= Self.maximumEnvelopeBytes, "GLM media envelope exceeds bound")
        return data
    }

    public static func decodeBounded(_ data: Data) throws -> Self {
        try workerRequire(!data.isEmpty && data.count <= maximumEnvelopeBytes, "GLM media envelope exceeds bound")
        try validateClusterWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClusterWorkerProtocolError.invalid("GLM media envelope must be an object")
        }
        return try decode(wire: object)
    }
}
