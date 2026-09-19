import Foundation
import MLX
import MLXNN
import XCTest
@testable import MLXLLM
@testable import MLXLMCommon

/// Native miniature target math and paged/recurrent state, not framework mocks.
/// Full-weight and HTTP qualification remain separate gates.
final class Qwen4LayerSubmissionStateProbeTests: XCTestCase {
    func testExactLogitsResidualAndRetainedStateAcrossFrontiers() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DARKBLOOM_QWEN4_LAYER_SAFETY_PROBE"] == "1"
            && env["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1")
        defer {
            if let value = env[Qwen4ExpLayerSubmission.flag] { setenv(Qwen4ExpLayerSubmission.flag, value, 1) }
            else { unsetenv(Qwen4ExpLayerSubmission.flag) }
            Qwen4ExpEnvironment.refresh()
        }
        let model = makeModel()
        var cells = 0
        let initial = Qwen4ExpLayerSubmissionInvocation.snapshot()
        for prefixCount in [13, 16, 19, 35] {
            let prefix = (0..<prefixCount).map { 1 + ($0 * 9 + 11) % 61 }
            for width in 1...6 {
                for kept in (width == 1 ? [1] : Array(0...width)) {
                    let baseline = try LayerSubmissionNativeState(model: model, enabled: false)
                    let candidate = try LayerSubmissionNativeState(model: model, enabled: true)
                    defer { try? baseline.close(); try? candidate.close() }
                    for start in stride(from: 0, to: prefix.count, by: 16) {
                        let tokens = Array(prefix[start..<min(start + 16, prefix.count)])
                        _ = try baseline.forward(tokens)
                        _ = try candidate.forward(tokens)
                    }
                    let tokens = (0..<width).map { 3 + $0 * 7 }
                    let before = Qwen4ExpLayerSubmissionInvocation.snapshot()
                    let expected = try baseline.forward(tokens, captured: width > 1, keep: kept)
                    XCTAssertEqual(Qwen4ExpLayerSubmissionInvocation.snapshot(), before)
                    let actual = try candidate.forward(tokens, captured: width > 1, keep: kept)
                    XCTAssertGreaterThan(Qwen4ExpLayerSubmissionInvocation.snapshot(), before)
                    let label = "prefix=\(prefixCount) width=\(width) kept=\(kept)"
                    exact(actual.logits, expected.logits, label + " logits")
                    exact(actual.hidden, expected.hidden, label + " residual")
                    try compare(candidate.snapshot(), baseline.snapshot(), label)
                    XCTAssertEqual(candidate.rows.map(\.absoluteOffset), baseline.rows.map(\.absoluteOffset))
                    let expectedSuffix = try baseline.forward([7, 11])
                    let actualSuffix = try candidate.forward([7, 11])
                    exact(actualSuffix.logits, expectedSuffix.logits, label + " suffix logits")
                    exact(actualSuffix.hidden, expectedSuffix.hidden, label + " suffix residual")
                    try compare(candidate.snapshot(), baseline.snapshot(), label + " suffix")
                    try baseline.close(); try candidate.close()
                    cells += 1
                }
            }
        }
        XCTAssertEqual(cells, 104)
        XCTAssertGreaterThan(Qwen4ExpLayerSubmissionInvocation.snapshot() - initial, 0)
        print("[qwen4-layer-state] exact_cells=\(cells) early_submissions=\(Qwen4ExpLayerSubmissionInvocation.snapshot() - initial)")
    }

    private func makeModel() -> Qwen4ExpTextModel {
        var c = Qwen4ExpTextConfiguration()
        c.hiddenSize = 64; c.hiddenLayers = 4; c.attentionHeads = 2; c.kvHeads = 1; c.headDim = 64
        c.linearNumValueHeads = 2; c.linearNumKeyHeads = 1
        c.linearKeyHeadDim = 64; c.linearValueHeadDim = 64
        c.vocabularySize = 64; c.maxPositionEmbeddings = 512
        c.fullAttentionInterval = 2
        c.layerTypes = ["linear_attention", "qwen_sparse_attention", "linear_attention", "qwen_sparse_attention"]
        c.hcCount = 2; c.hcLowrank = 8; c.pleLayerIds = []; c.pleEmbedDim = 64
        c.indexerNHeads = 2; c.indexerKVHeads = 1; c.indexerHeadDim = 32
        c.indexerBudget = 16; c.indexerCompressRatio = 4
        c.numExperts = 1; c.numExpertsPerTok = 1
        c.sharedExpertIntermediateSize = 32; c.moeIntermediateSize = 32
        c.mropeSection = [2, 1, 1]; c.partialRotaryFactor = 0.25
        MLXRandom.seed(8301)
        let model = Qwen4ExpTextModel(c)
        model.update(parameters: ModuleParameters.unflattened(
            model.parameters().flattened().map { ($0.0, $0.1.asType(.bfloat16)) }))
        eval(model)
        return model
    }

    private func exact(_ actual: MLXArray, _ expected: MLXArray, _ label: String) {
        XCTAssertEqual(actual.shape, expected.shape, label)
        XCTAssertEqual(actual.dtype, expected.dtype, label)
        eval(actual, expected)
        XCTAssertTrue(actual.asData(access: .copy).data == expected.asData(access: .copy).data, label)
    }

    private func compare(_ actual: [String: MLXArray], _ expected: [String: MLXArray], _ label: String) throws {
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), label)
        for key in expected.keys.sorted() { exact(try XCTUnwrap(actual[key]), expected[key]!, label + " " + key) }
    }
}

private final class LayerSubmissionNativeState {
    let model: Qwen4ExpTextModel
    let enabled: Bool
    let backend: PagedKVBackend
    let caches: [PagedLayerCache]
    let rows: [PagedSequenceKV]
    let recurrent: CBv2RecurrentRequestState
    private var closed = false

    init(model: Qwen4ExpTextModel, enabled: Bool) throws {
        self.model = model; self.enabled = enabled
        backend = try PagedKVBackend(layerKinds: model.cbv2LayerKinds, config: .init(
            capacityBytes: 64 << 20, maxPrefillChunk: 16, nominalMaxSequenceLength: 512,
            segmentSizeBytes: 32768, layerDTypes: [.bfloat16, .bfloat16]))
        caches = backend.makeLayerCaches()
        rows = try backend.makeSequenceState(layerKinds: model.cbv2LayerKinds,
            promptLength: 0, maxLength: 512).map { try XCTUnwrap($0 as? PagedSequenceKV) }
        recurrent = try CBv2RecurrentRequestState(spec: model.cbv2RecurrentStateSpec)
        for (cache, row) in zip(caches, rows) { cache.setRows([row]) }
    }

    func close() throws {
        guard !closed else { return }
        Stream.gpu.synchronize(); Stream.cpu.synchronize()
        for cache in caches { cache.setRows([]) }
        backend.release(rows.map { $0 as CBv2SequenceKV? })
        try recurrent.release()
        XCTAssertEqual(backend.bytesReserved, 0); XCTAssertEqual(backend.bytesWired, 0)
        closed = true
    }

    func forward(_ tokens: [Int], captured: Bool = false, keep: Int? = nil)
        throws -> (logits: MLXArray, hidden: MLXArray) {
        setenv(Qwen4ExpLayerSubmission.flag, enabled ? "1" : "0", 1)
        Qwen4ExpEnvironment.refresh()
        for (cache, row) in zip(caches, rows) { cache.setRows([row]) }
        let input = MLXArray(tokens.map(Int32.init), [1, tokens.count])
        let transaction = try recurrent.bind()
        let fill = CBv2DeferredHostFill.open()
        defer { fill.close(); fill.run() }
        if captured { for row in rows { row.beginSpeculativeWrite() } }
        for cache in caches { cache.mtpSerializesRectangularAttention = captured }
        let output = captured
            ? model.cbv2ForwardWithHiddenCaptured(input, caches: caches, recurrentState: [transaction], positionIds: nil)
            : model.cbv2ForwardWithHidden(input, caches: caches, recurrentState: [transaction], positionIds: nil)
        try backend.pool.writeValidation.check()
        let roots = try transaction.evaluate()
        fill.close(); fill.run()
        eval([output.logits, output.lastHidden] + roots + caches.flatMap { $0.innerState() })
        if captured {
            let retained = keep ?? tokens.count
            if retained == 0 { try transaction.rollback() }
            else { try transaction.commit(keepPositions: retained) }
            for (cache, row) in zip(caches, rows) {
                CBv2Qwen4IndexerBind.harvest(cache, into: row)
                row.rollback(tokens.count - retained); row.commitSpeculativeWrite()
                try row.trimQwen4Indexer(to: row.absoluteOffset, compressRatio: model.configuration.indexerCompressRatio)
                _ = CBv2Qwen4IndexerBind.restore(cache, from: row)
                cache.setRows([row]); cache.mtpSerializesRectangularAttention = false
            }
        } else { try transaction.commit() }
        return (output.logits, output.lastHidden)
    }

    func snapshot() throws -> [String: MLXArray] {
        var result: [String: MLXArray] = [:]
        for (i, row) in rows.enumerated() {
            let kv = row.snapshot(), side = try row.snapshotQwen4Indexer()
            result["kv.\(i).keys"] = kv.keys; result["kv.\(i).values"] = kv.values
            result["qsa.\(i).keys"] = side.indexKeys; result["qsa.\(i).positions"] = side.positionIds
            result["qsa.\(i).pooled"] = side.pooledIndexKeys
        }
        for (i, layer) in try XCTUnwrap(recurrent.confirmedStateSnapshot()) {
            result["gdn.\(i).conv"] = layer.conv; result["gdn.\(i).ssm"] = layer.ssm
        }
        eval(Array(result.values))
        return result
    }
}
