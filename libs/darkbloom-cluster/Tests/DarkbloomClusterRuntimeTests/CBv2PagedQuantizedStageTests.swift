import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// Main's live KV quantization on a stage KV host, on the synthetic Qwen 3.5 of
// `CBv2PagedBatchSyntheticTests` (head_dim 64: group 64, Hadamard 64). Prompts
// run past the 128 recent native tokens, so attention reads packed history.
// The host's pool is main's pool, built and probed the way the provider builds
// it; one request decoded through the stage's owned state must give exactly
// the tokens main's own engine gives on the same packed pool; batched lanes
// still equal each request alone, bit for bit; a speculative window settles
// inside main's row transaction, and no request's step completes under another's
// open window; a refused write fails its step before evaluation; nothing adopts
// native arrays into packed rows.
//
// A contract test on a synthetic model, not a model or hardware result.

@Suite("Quantized stage KV follows main's packed pool (synthetic Qwen 3.5, no artifact)", .serialized)
struct CBv2PagedQuantizedStageTests {
    typealias Synthetic = CBv2PagedBatchSyntheticTests
    static let chunk = 16
    static let prompt = (0..<200).map { ($0 * 37 + 11) % Synthetic.vocabulary }
    static let outputs = 24

    static func host(_ model: Qwen35TextModel, _ selection: PagedKVQuantizationSelection, lanes: Int = 1)
        throws -> CBv2StageKVHost {
        try CBv2StageKVHost(model: model, kind: .paged, lanes: lanes, maximumTokensPerRequest: 256,
            maximumChunkTokens: chunk, quantization: selection)
    }

    static func lastToken(_ output: MLXArray) -> Int {
        let rows = output.reshaped([-1, Synthetic.vocabulary])
        return Int(argMax(rows[rows.dim(0) - 1], axis: -1).item(UInt32.self))
    }

    @Test(arguments: [PagedKVQuantizationSelection.balanced, .k8v4, .k8v8])
    func everyLivePrecisionBuildsMainsPackedPoolAndPricesItsRows(selection: PagedKVQuantizationSelection) throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, selection, lanes: 2)
        let paged = try #require(host.backend as? PagedKVBackend)
        #expect(paged.usesQuantizedStorage && paged.prefixReuseBackend == .unknown)
        for index in host.layerKinds.indices {
            #expect(paged.pool.groupKey(forLayer: index).quantization == selection.configuration)
        }
        let pages = try CBv2StageKVHost.pagedRequestBytes(kinds: host.layerKinds, dtype: host.kvDType,
            quantization: selection, maximumTokens: 256, maximumChunkTokens: Self.chunk)
        #expect(host.requestPageBytes == pages && host.capacityBytes == 2 * pages + CBv2StageKVHost.segmentBytes)
        let admitted = try paged.pool.admissionStorageConfig(.init(watermarkFraction: 0))
        #expect(host.nativeRecentBytesPerRequest == admitted.minimumRequestTransientBytes)
        let native = try Self.host(model, .native, lanes: 2)
        #expect(host.requestPageBytes < native.requestPageBytes && native.nativeRecentBytesPerRequest == 0)
        // The native pool is the one the host always built.
        let config = try #require(native.backend as? PagedKVBackend).pool.config
        #expect(config.quantization == nil && config.nativeLayerIndices.isEmpty)
        #expect(config.prefixSharingBlockSize == nil && config.gatheredAttention == nil)
        #expect(config.capacityBytes == native.capacityBytes && config.dtype == native.kvDType
            && config.maxPrefillChunk == Self.chunk && config.nominalMaxSequenceLength == 256
            && config.segmentSizeBytes == 64 << 20 && config.layerDTypes == Array(repeating: native.kvDType,
                count: native.layerKinds.count) && config.maxBufferLength == GPU.deviceInfo().maxBufferSize)
        let rows = (256 + CBv2PagedDefaults.pageSize - 1) / CBv2PagedDefaults.pageSize * CBv2PagedDefaults.pageSize
        #expect(native.requestPageBytes == native.layerKinds.reduce(0) {
            $0 + rows * $1.kvHeads * $1.headDim * native.kvDType.size * 2
        })
    }

    /// One request through the stage's owned state: chunked prefill and
    /// one-token decode by the same adapter entries main's engine calls.
    static func stageDecode(_ model: Qwen35TextModel, host: CBv2StageKVHost) throws -> [Int] {
        let adapter = CBv2SteppableLanguageModelAdapter(model)
        let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host,
            maximumTokens: prompt.count + outputs), promptCount: prompt.count, outputCount: outputs)
        var offset = 0, last: MLXArray?
        while offset < prompt.count {
            let part = Array(prompt[offset..<min(prompt.count, offset + chunk)])
            let final = offset + part.count == prompt.count
            last = try state.run(tokenCount: part.count, check: {}, forward: { caches, evaluation in
                adapter.recurrentPrefill(tokens: MLXArray(part.map(Int32.init)).reshaped([1, part.count]),
                    inputEmbeddings: nil, caches: caches, recurrentState: [evaluation], positionIds: nil,
                    requirement: final ? .lastPositionLogits : .evaluationOnly)
            }, validateOutput: { _ in })
            offset += part.count
        }
        var tokens = [lastToken(try #require(last))]
        while tokens.count < outputs {
            let token = tokens.last!
            let logits = try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                adapter.forward(tokens: MLXArray([Int32(token)]).reshaped([1, 1]), caches: caches,
                    recurrentState: [evaluation], positionIds: nil)
            }, validateOutput: { _ in })
            tokens.append(lastToken(logits))
        }
        try state.retire()
        return tokens
    }

    /// The same request on main's engine, on a pool from the same builder.
    static func engineDecode(_ model: Qwen35TextModel, _ selection: PagedKVQuantizationSelection) async throws -> [Int] {
        let kinds = model.cbv2LayerKinds
        let backend = try PagedKVBackend.segmented(admittedGrantBytes: 64 << 20, layerKinds: kinds,
            layerDTypes: Array(repeating: .bfloat16, count: kinds.count), maxPrefillChunk: chunk,
            nominalMaxSequenceLength: 256, maxBufferLength: GPU.deviceInfo().maxBufferSize,
            quantization: selection.configuration)
        let storage = backend.makeLayerCaches()
        let positions = Dictionary(uniqueKeysWithValues: kinds.enumerated().map {
            ($0.element.modelLayerIndex ?? $0.offset, $0.offset)
        })
        let caches = model.newCacheV2 { layer, _ in storage[positions[layer]!] }
        let engine = EngineV2(model: CBv2SteppableLanguageModelAdapter(model), layerKinds: kinds, backend: backend,
            cacheProvider: CBv2LayerCacheBank(caches: caches), sampler: CBv2GreedySampler(),
            schedulerConfig: .init(maxConcurrentRequests: 1, maxBatchedTokensPerStep: 64, prefillChunkSize: chunk,
                maxWaiting: 4, enablePrefixCache: false))
        var tokens: [Int] = []
        do {
            for await event in try engine.submit(.init(id: .init(1), promptTokens: prompt,
                sampling: .init(temperature: 0), maxTokens: outputs, prefixCacheEnabled: false)) {
                if case .delta(_, let new, _) = event { tokens += new }
            }
        } catch {
            await engine.shutdown()
            throw error
        }
        await engine.shutdown()
        #expect(backend.bytesInUse == 0 && backend.bytesReserved == 0)
        return tokens
    }

    @Test(arguments: [PagedKVQuantizationSelection.balanced, .k8v4, .k8v8])
    func stageDecodeEqualsMainsEngineOnTheSamePackedPool(selection: PagedKVQuantizationSelection) async throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, selection)
        let stage = try Self.stageDecode(model, host: host)
        #expect(host.isDrained)
        let main = try await Self.engineDecode(model, selection)
        #expect(stage.count == Self.outputs)
        #expect(stage == main, "\(selection): the stage's packed decode differs from main's engine")
    }

    @Test func nativeStageDecodeStillEqualsMainsEngine() async throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, .native)
        let stage = try Self.stageDecode(model, host: host)
        let main = try await Self.engineDecode(model, .native)
        #expect(stage == main, "the native stage decode differs from main's engine")
    }

    @Test func packedLanesStillEqualEachRequestAloneBitForBit() throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, .balanced, lanes: 3)
        let prompts = [150, 170, 140].enumerated().map { lane, count in
            (0..<count).map { ($0 * (31 + lane) + 7 * lane + 3) % Synthetic.vocabulary }
        }
        func prefill(_ prompt: [Int]) throws -> (CBv2OwnedRequestState, MLXArray) {
            let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host, maximumTokens: 256),
                promptCount: prompt.count, outputCount: 8)
            return (state, try Synthetic.prefill(model, state, prompt))
        }
        // Each request alone: its logits rows.
        var alone: [[MLXArray]] = []
        for prompt in prompts {
            let (state, first) = try prefill(prompt)
            var row = first, rows = [first]
            while rows.count < 8 {
                let token = Synthetic.argmax(row)
                row = try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                    Synthetic.logits(model, [[token]], caches: caches, evaluations: [evaluation])
                }, validateOutput: { _ in })
                rows.append(row)
            }
            try state.retire()
            alone.append(rows)
        }
        #expect(host.isDrained)
        // Together: every lane prefilled alone, then decoded in one batch.
        let started = try prompts.map(prefill)
        var states = started.map { $0.0 }, last = started.map { $0.1 }
        for step in 1..<8 {
            let tokens = last.map(Synthetic.argmax)
            let rows = try CBv2OwnedRequestState.runBatch(states, tokenCount: 1, check: {},
                forward: { caches, evaluations in
                    Synthetic.logits(model, tokens.map { [$0] }, caches: caches, evaluations: evaluations)
                }, validateOutput: { _ in })
            for lane in states.indices {
                let batched = rows[lane].asType(.float32).asArray(Float.self)
                #expect(batched == alone[lane][step].asType(.float32).asArray(Float.self),
                    "lane \(lane) step \(step) differs from its packed solo row")
                last[lane] = rows[lane]
            }
        }
        for state in states { try state.retire() }
        states.removeAll()
        #expect(host.isDrained)
    }

    @Test func aPackedWindowSettlesInsideMainsRowTransaction() throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, .balanced)
        let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host, maximumTokens: 256),
            promptCount: Self.prompt.count, outputCount: 16)
        let next = Synthetic.argmax(try Synthetic.prefill(model, state, Self.prompt))
        let drafts = [next, 17, 42, 7]
        let input = MLXArray(drafts.map(Int32.init)).reshaped([1, drafts.count])
        let built = try state.beginWindow(tokenCount: drafts.count) { caches, evaluation in
            [model.cbv2ForwardWithHiddenCaptured(input, caches: caches.map { $0 as! any KVCache },
                recurrentState: [evaluation], positionIds: nil).logits]
        }
        eval(built.outputs + built.roots)
        try state.confirmWindow(check: {})
        eval(try state.settleWindow(keeping: 2))
        try state.confirmSettled(check: {})
        #expect(state.committedTokens == Self.prompt.count + 2)
        // The settled rows decode on: the transaction closed and the band was
        // compacted to the confirmed frontier.
        let paged = try #require(host.backend as? PagedKVBackend)
        let band = paged.pool.nativeRecentBytesInUse
        let decoded = try state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
            Synthetic.logits(model, [[3]], caches: caches, evaluations: [evaluation])
        }, validateOutput: { _ in })
        #expect(decoded.shape == [1, Synthetic.vocabulary])
        #expect(paged.pool.nativeRecentBytesInUse <= band, "the packed band grew past its recent rows")
        try state.retire()
        #expect(host.isDrained)
    }

    @Test func aRefusedPackedWriteFailsItsStepBeforeEvaluationAndTheNextRequestStartsClean() throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, .balanced)
        let reference = try Self.stageDecode(model, host: Self.host(model, .balanced))
        let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host, maximumTokens: 256),
            promptCount: 8, outputCount: 8)
        // A projection that hands the pool another dtype: the write is refused
        // and the attention returns a placeholder, which must never evaluate.
        var evaluated = false
        #expect(throws: CBv2PagedKVWriteError.self) {
            _ = try state.run(tokenCount: 1, check: {}, forward: { caches, _ in
                let cache = caches.first { $0 is PagedLayerCache } as! PagedLayerCache
                let kind = cache.kind
                let queries = MLXArray.zeros([1, kind.queryHeads, 1, kind.headDim], dtype: .float32)
                let keys = MLXArray.zeros([1, kind.kvHeads, 1, kind.headDim], dtype: .float32)
                return cache.updateAndAttend(queries: queries, keys: keys, values: keys,
                    scale: 1, sinks: nil)
            }, validateOutput: { _ in evaluated = true })
        }
        #expect(!evaluated && state.isFailed)
        try? state.retire(failed: true)
        #expect(host.isDrained)
        // The latch and the step's scratch went with the failed request.
        #expect(try Self.stageDecode(model, host: host) == reference)
    }

    @Test func aPackedStepNeverCompletesUnderAnotherRequestsOpenWindow() throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, .balanced, lanes: 2)
        func started() throws -> (CBv2OwnedRequestState, Int) {
            let state = try CBv2OwnedRequestState(geometry: Synthetic.geometry(model, host: host, maximumTokens: 256),
                promptCount: Self.prompt.count, outputCount: 16)
            return (state, Synthetic.argmax(try Synthetic.prefill(model, state, Self.prompt)))
        }
        let (windowed, next) = try started()
        let (other, token) = try started()
        let input = MLXArray([Int32(next), 17]).reshaped([1, 2])
        let built = try windowed.beginWindow(tokenCount: 2) { caches, evaluation in
            [model.cbv2ForwardWithHiddenCaptured(input, caches: caches.map { $0 as! any KVCache },
                recurrentState: [evaluation], positionIds: nil).logits]
        }
        eval(built.outputs + built.roots)
        #expect(host.openPackedWindows == 1)
        #expect(throws: ProbeError.self) {
            _ = try other.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                Synthetic.logits(model, [[token]], caches: caches, evaluations: [evaluation])
            }, validateOutput: { _ in })
        }
        try? other.retire(failed: true)
        try windowed.confirmWindow(check: {})
        eval(try windowed.settleWindow(keeping: 1))
        try windowed.confirmSettled(check: {})
        #expect(host.openPackedWindows == 0 && windowed.committedTokens == Self.prompt.count + 1)
        try windowed.retire()
        #expect(host.isDrained)
    }

    @Test func nativeArraysNeverAdoptIntoPackedRows() throws {
        let model = try Synthetic.model()
        let host = try Self.host(model, .balanced)
        let geometry = try Synthetic.geometry(model, host: host, maximumTokens: 256)
        do {
            _ = try CBv2OwnedRequestState(geometry: geometry, promptCount: 32, outputCount: 8,
                adoptingCommittedTokens: 32, attention: [:], recurrent: [:])
            Issue.record("a packed host adopted native arrays")
        } catch let error as ProbeError {
            #expect(error.description.contains("native live precision"))
        }
        #expect(host.isDrained)
    }
}
