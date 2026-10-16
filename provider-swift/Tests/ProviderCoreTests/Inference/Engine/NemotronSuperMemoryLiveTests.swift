// Copyright © 2026 Eigen Labs.

import Darwin
import Foundation
import MLX
@testable import MLXLLM
@testable import MLXLMCommon
@testable import MLXVLM
import Testing
@testable import ProviderCore

/// Gated full-checkpoint memory ledger of the Super owner's native pieces,
/// each measured as MLX active memory, its peak and the process footprint
/// around one phase: installation and the embedded head against their LOAD
/// quotes; every 2,048-token prompt chunk of one long prompt and plain decode
/// steps (the bytes each context token adds, and each chunk's transient
/// against the prefill lane) on contiguous and paged KV storage; one chunk
/// under the stage profile's memory recording; the largest image grid's
/// tower and projector against the media activation bound. Loads about
/// 75 GB; run only with exclusive GPU access, `DARKBLOOM_SUPER_MEMORY_LIVE=1`
/// and `NEMOTRON_SUPER_CHECKPOINT_DIR`. `DARKBLOOM_SUPER_MEMORY_PROMPT`
/// (tokens, default 16,000), `DARKBLOOM_SUPER_MEMORY_DECODE` (steps, default
/// 16; above 256 crosses the contiguous rows' initial slack) and
/// `DARKBLOOM_SUPER_MEMORY_BACKENDS` (`contiguous,paged` by default) size the
/// sweep.
struct NemotronSuperMemoryLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["DARKBLOOM_SUPER_MEMORY_LIVE"] == "1"
        && environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil
    static let chunk = NemotronSuperLocalPrefill.defaultChunkTokens
    static let promptTokens = Int(environment["DARKBLOOM_SUPER_MEMORY_PROMPT"] ?? "") ?? 16_000
    static let decodeSteps = Int(environment["DARKBLOOM_SUPER_MEMORY_DECODE"] ?? "") ?? 16
    static let backends = (environment["DARKBLOOM_SUPER_MEMORY_BACKENDS"] ?? "contiguous,paged")
        .split(separator: ",").map(String.init)
    static var maximumLength: Int { promptTokens + decodeSteps + 64 }

    enum Failure: Error { case layout }

    static func footprint() -> Int {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? Int(info.ri_phys_footprint) : -1
    }

    /// Active memory and its peak around `body`, both relative to the active
    /// memory when it started, and the process footprint and MLX cache after.
    struct Phase {
        let base: Int
        let retained: Int
        let peak: Int
        let footprint: Int
        let cache: Int
        var transient: Int { peak - max(retained, 0) }
    }

    /// `clearCache` returns MLX's cached buffers first, so a phase's footprint
    /// shows what it retains (live and cached) rather than earlier phases'.
    static func measure<T>(clearCache: Bool = true, _ body: () throws -> T) rethrows -> (T, Phase) {
        MLX.Stream().synchronize()
        if clearCache { Memory.clearCache() }
        let base = Memory.activeMemory
        Memory.peakMemory = 0
        let value = try body()
        MLX.Stream().synchronize()
        let after = Memory.activeMemory
        let peak = max(Memory.peakMemory, after)
        return (value, Phase(base: base, retained: after - base, peak: peak - base,
            footprint: footprint(), cache: Memory.cacheMemory))
    }

    static func report(_ label: String, _ phase: Phase, _ extra: String = "") {
        print("SUPER_MEMORY \(label) base=\(phase.base) retained=\(phase.retained) peak=\(phase.peak) "
            + "transient=\(phase.transient) footprint=\(phase.footprint) cache=\(phase.cache) \(extra)")
    }

    /// One request over the installed model on the selected storage (the
    /// paged live test's arms).
    final class Lane {
        let adapter: NemotronSuperRecurrentAdapter
        let backend: any CBv2KVBackend
        let bank: CBv2LayerCacheBank
        let rows: [CBv2SequenceKV?]
        let state: CBv2RecurrentRequestState

        init(_ model: NemotronSuperModel, paged: Bool) throws {
            adapter = NemotronSuperRecurrentAdapter(model)
            let kinds = model.cbv2LayerKinds
            let length = NemotronSuperMemoryLiveTests.maximumLength
            if paged {
                let types = try #require(model.languageModel.observedAttentionKVDTypes())
                let rate = try NemotronSuperDecodeCharge.attentionKVBytesPerToken(
                    configuration: model.languageModel.configuration, elementBytes: types[0].size)
                let bytes = rate * length + (256 << 20)
                let paged = try PagedKVBackend(layerKinds: kinds,
                    config: .init(capacityBytes: bytes, dtype: types[0], maxPrefillChunk: chunk,
                        nominalMaxSequenceLength: length, maxBufferLength: MLX.GPU.deviceInfo().maxBufferSize,
                        segmentSizeBytes: 64 << 20, layerDTypes: types))
                let storage = paged.makeLayerCaches()
                let slots = Dictionary(uniqueKeysWithValues: kinds.enumerated().map {
                    ($0.element.modelLayerIndex ?? $0.offset, $0.offset)
                })
                backend = paged
                bank = CBv2LayerCacheBank(caches: try model.languageModel.newCacheV2 { index, _ in
                    guard let slot = slots[index] else { throw Failure.layout }
                    return storage[slot]
                })
            } else {
                backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 40, kvDType: .bfloat16))
                bank = CBv2LayerCacheBank(caches: model.languageModel.newCacheV2 {
                    CBv2LayerCache(layerIndex: $0, kind: $1)
                })
            }
            rows = try backend.makeSequenceState(layerKinds: kinds, promptLength: promptTokens, maxLength: length)
            state = try CBv2RecurrentRequestState(spec: model.cbv2RecurrentStateSpec)
        }

        private func caches() -> [KVCache] {
            bank.layerCaches(rowStates: [rows]).map { $0 as! KVCache }
        }

        func prefill(_ tokens: ArraySlice<Int32>) throws -> Int32 {
            let cache = caches()
            let binding = try state.bind()
            let logits = adapter.cbv2RecurrentPrefill(MLXArray(Array(tokens)).reshaped(1, tokens.count),
                inputEmbedding: nil, cache: cache, recurrentState: [binding], positionIds: nil,
                requirement: .lastPositionLogits)
            let token = argMax(logits.reshaped(-1, logits.dim(-1))[-1])
            eval([token] + (try binding.evaluate()) + cache.flatMap { $0.innerState() })
            try binding.commit()
            return token.item(Int32.self)
        }

        func decode(_ token: Int32) throws -> Int32 {
            let cache = caches()
            let binding = try state.bind()
            let logits = adapter.cbv2Forward(MLXArray([token]).reshaped(1, 1), caches: cache,
                recurrentState: [binding])[0, -1]
            let next = argMax(logits)
            eval([next] + (try binding.evaluate()) + cache.flatMap { $0.innerState() })
            try binding.commit()
            return next.item(Int32.self)
        }

        /// Every attention row's storage: type, element dtype and bytes.
        func storage() -> String {
            let rows = rows.compactMap { $0 }
            let bytes = rows.reduce(0) { $0 + (($1 as? CBv2FullSequenceKV)?.byteCount ?? 0) }
            let kinds = Set(rows.map { row -> String in
                let snapshot = row.snapshot()
                return "\(type(of: row)) \(snapshot.keys.dtype) offset=\(snapshot.offset)"
            })
            return "rows=\(rows.count) contiguous_bytes=\(bytes) backend_reserved=\(backend.bytesReserved) "
                + kinds.sorted().joined(separator: "; ")
        }

        func release() throws {
            bank.releaseBoundRows()
            try state.release()
            backend.release(rows)
        }
    }

    /// Prefills `prompt` chunk by chunk, then decodes, printing every phase;
    /// returns the largest chunk transient.
    static func sweep(_ lane: Lane, prompt: [Int32], label: String) throws -> Int {
        let start = Memory.activeMemory
        let laneBound = NemotronHModel.prefillActivationBoundBytes(tokens: chunk)
        var token: Int32 = 0
        var largest = 0
        for begin in stride(from: 0, to: prompt.count, by: chunk) {
            let end = min(prompt.count, begin + chunk)
            let (next, phase) = try measure(clearCache: false) { try lane.prefill(prompt[begin ..< end]) }
            token = next
            largest = max(largest, phase.transient)
            report("\(label) chunk end=\(end)", phase,
                "held=\(Memory.activeMemory - start) lane_bound=\(laneBound)")
            if end == prompt.count || begin == 0 { print("SUPER_MEMORY \(label) kv \(lane.storage())") }
        }
        for step in 0 ..< decodeSteps {
            let (next, phase) = try measure(clearCache: false) { try lane.decode(token) }
            token = next
            if step < 2 || step % 64 == 0 || phase.retained != 0 || step == decodeSteps - 1 {
                report("\(label) decode step=\(step) tokens=\(prompt.count + step + 1)", phase,
                    "held=\(Memory.activeMemory - start)")
            }
        }
        print("SUPER_MEMORY \(label) kv after decode \(lane.storage())")
        let (_, cleared) = measure { 0 }
        report("\(label) end tokens=\(prompt.count + decodeSteps)", cleared,
            "held=\(Memory.activeMemory - start) largest_chunk_transient=\(largest)")
        return largest
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(60)))
    func pinnedCheckpointMemoryLedger() async throws {
        let directory = URL(fileURLWithPath: try #require(Self.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"]),
            isDirectory: true)
        let inputs = try NemotronSuperCheckpoint.Inputs(directory: directory)
        let files = try await NemotronSuperCheckpoint.openShards(directory: directory,
            names: inputs.inventory.shards, parallelism: 8)
        let source = try ModelOptCheckpointSource(indexData: inputs.indexData,
            indexSHA256: inputs.indexSHA256, files: files)
        let configuration = try NemotronSuperImageConfiguration(data: inputs.configData)
        let allowance = NemotronSuperServingPolicy.backendAllowanceBytes
        let quote = try NemotronSuperInstallation.loadQuote(source: source, backendAllowanceBytes: allowance)
        let construction = NativeConstructionScope()

        // Installation against its quote (payload, staging and allowance).
        let (installed, install) = try Self.measure {
            try NemotronSuperInstallation.stage(configuration: configuration, source: source,
                residency: try NemotronSuperResidency(capacityBytes: quote.totalBytes, maximumRequests: 1),
                backendAllowanceBytes: allowance, construction: construction)
        }
        defer { installed.closeAfterRetirement() }
        Self.report("install", install, "payload=\(quote.payloadBytes) staging=\(quote.stagingBytes)")
        #expect(install.peak <= quote.totalBytes)

        // The embedded head against its supplement, after the installation's
        // staging buffers left the cache (as the managed load does).
        let headQuote = try NemotronSuperMTPServing.loadQuote(configuration: configuration, source: source)
        let (head, headLoad) = try Self.measure {
            try NemotronSuperMTPServing.loadHead(installed: installed, source: source, quote: headQuote,
                construction: construction)
        }
        Self.report("head", headLoad, "head_payload=\(headQuote.payloadBytes) "
            + "head_construction=\(headQuote.constructionBytes)")
        #expect(headLoad.peak <= headQuote.payloadBytes + headQuote.constructionBytes)
        let claim = try NemotronSuperLoadClaim.bytes(installation: quote, head: headQuote, sequential: true)
        print("SUPER_MEMORY load_summary claim=\(claim) resident=\(install.retained + headLoad.retained) "
            + "peak=\(max(install.peak, install.retained + headLoad.peak))")
        _ = head

        let model = try #require(installed.model)
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let encoded = tokenizer.encode(
            text: NemotronSuperPagedLiveTests.prose(words: Self.promptTokens * 7 / 8 + 2_000),
            addSpecialTokens: false)
        try #require(encoded.count >= Self.promptTokens, "prose encodes to \(encoded.count) tokens")
        let prompt: [Int32] = encoded.prefix(Self.promptTokens).map { Int32($0) }

        // The context sweep on each storage.
        let laneBound = NemotronHModel.prefillActivationBoundBytes(tokens: Self.chunk)
        for name in Self.backends {
            let (lane, created) = try Self.measure { try Lane(model, paged: name == "paged") }
            Self.report("\(name) lane_created", created)
            let largest = try Self.sweep(lane, prompt: prompt, label: name)
            #expect(largest <= laneBound)
            try lane.release()
            let (_, released) = Self.measure { 0 }
            Self.report("\(name) released", released)
        }

        // Fenced experiment: the same first chunks with the residual stream
        // evaluated every `fence` layers (results unchanged; bounds the
        // intermediates queued command buffers retain), timed.
        for fence in [nil, 8, 2] as [Int?] {
            model.languageModel.setSuperPrefillFenceLayers(fence)
            let fenced = try Lane(model, paged: false)
            for begin in stride(from: 0, to: 3 * Self.chunk, by: Self.chunk) {
                let started = DispatchTime.now().uptimeNanoseconds
                let (_, phase) = try Self.measure(clearCache: false) {
                    try fenced.prefill(prompt[begin ..< begin + Self.chunk])
                }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
                Self.report("fence=\(fence.map(String.init) ?? "none") chunk end=\(begin + Self.chunk)", phase,
                    String(format: "seconds=%.3f", seconds))
            }
            try fenced.release()
        }
        model.languageModel.setSuperPrefillFenceLayers(nil)

        // One chunk again under the stage profile with memory recording.
        let profiled = try Lane(model, paged: false)
        let recorder = NemotronSuperProfileRecorder(recordsMemory: true)
        let (_, profiledPhase) = try NemotronSuperPrefillProfile.$recorder.withValue(recorder) {
            try Self.measure { try profiled.prefill(prompt[0 ..< Self.chunk]) }
        }
        Self.report("profiled_chunk", profiledPhase)
        for line in recorder.report().split(separator: "\n") where line.hasPrefix("memory ") {
            print("SUPER_MEMORY_STAGE \(line)")
        }
        try profiled.release()

        // The largest admitted grid's tower and projector.
        let grid = try #require(NemotronSuperServingPolicy.largestImageGrid)
        let height = grid.heightPatches * 16, width = grid.widthPatches * 16
        let count = 3 * height * width
        let pixels = (MLXArray(Int32(0) ..< Int32(count)).asType(.float32) * (2 / Float(count)) - 1)
            .reshaped(1, 3, height, width)
        eval(pixels)
        let (_, image) = try Self.measure {
            let features = try model.imageComposition.imageFeatures(normalizedPixels: pixels)
            eval(features)
            return features.shape
        }
        let imageBound = try NemotronSuperLocalImageBinding.towerActivationBytes(
            [(grid.heightPatches, grid.widthPatches)])
        Self.report("image_tower grid=\(grid.heightPatches)x\(grid.widthPatches)", image,
            "activation_bound=\(imageBound)")
        #expect(UInt64(image.peak) <= imageBound)
    }
}
