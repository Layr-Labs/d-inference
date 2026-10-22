#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX
@_spi(OwnedTargetVerification) import MLXLMCommon

enum AttentionVerificationFixture {
    static func require(_ value: Bool, _ message: String) throws {
        try WindowedStateFixtureOwner.require(value, message)
    }
    static func fill(_ owner: WindowedStateFixtureOwner, to frontier: Int) throws {
        while owner.state.committedTokens < frontier {
            try owner.advance(min(7, frontier - owner.state.committedTokens))
        }
    }
    // No model GEMM here: exact representable positional KV and zero queries
    // isolate storage/attention chronology from full-model batch-shape numerics.
    static func forward(_ caches: [any CBv2AttendingLayerCache], count: Int,
                        layers: Int = 2) throws -> MLXArray {
        var columns: [MLXArray] = []
        for index in 0..<layers {
            let cache = caches[index], kind = WindowedStateFixtureModel.kinds[index]
            let dtype = WindowedStateFixtureModel.dtypes[index]
            let start = Int(cache.positionOffsets.item(Int32.self))
            let keys = WindowedStateFixtureModel.tensor(kind: kind, start: start, count: count,
                dtype: dtype, values: false)
            let values = WindowedStateFixtureModel.tensor(kind: kind, start: start, count: count,
                dtype: dtype, values: true)
            let query = MLXArray.zeros([1, kind.queryHeads, count, kind.headDim], dtype: dtype)
            let result = cache.updateAndAttend(queries: query, keys: keys, values: values, scale: 1, sinks: nil)
            columns.append(result.asType(.float32).sum(axis: 3).sum(axis: 1).reshaped([1, count]))
        }
        return concatenated(columns, axis: 0)
    }
    static func validate(_ output: MLXArray, width: Int) throws {
        try require(output.shape == [2, width] && output.dtype == .float32
            && output.asArray(Float.self).allSatisfy({ $0.isFinite }), "Synthetic rectangular output differs")
    }
    static func admit(_ plan: CBv2AttentionVerificationPlan) throws {
        try require(plan.layout.layers.count == 2 && plan.layout.maximumTokens == 32
            && plan.layout.maximumChunkTokens == 7 && plan.additionalLogicalBytes <= 32 * 1024
            && plan.backendCapacityBytes <= 32 * 1024, "Tiny fixture state allowance exceeded")
    }
    static func begin(_ owner: WindowedStateFixtureOwner, width: Int) throws {
        try owner.state.beginAttentionVerification(steps: width, captureLayerIndices: [0, 1],
            admit: admit, check: owner.check)
    }
    static func stage(_ owner: WindowedStateFixtureOwner, width: Int) throws -> MLXArray {
        try owner.state.stageAttentionVerification(check: owner.check, additionalTargets: { [] },
            forward: { try forward($0, count: width) }, validateOutput: { try validate($0, width: width) })
    }
    static func serial(_ owner: WindowedStateFixtureOwner, width: Int) throws -> MLXArray {
        var outputs: [MLXArray] = []
        for _ in 0..<width {
            outputs.append(try owner.state.run(tokenCount: 1, check: owner.check,
                forward: { caches, _ in try forward(caches, count: 1) },
                validateOutput: { try validate($0, width: 1) }))
        }
        return concatenated(outputs, axis: 1)
    }
    static func sameShapeReference(_ owner: WindowedStateFixtureOwner, width: Int, keep: Int) throws -> CBv2OwnedStateSnapshot {
        let state = owner.state, base = state.committedTokens
        // Direct existing SDK transaction, independent of the new owner bridge.
        for row in state.rows { row!.beginSpeculativeWrite() }
        let caches = state.bank.layerCaches(rowStates: [state.rows])
        let result = try CBv2OwnedRectangularAttention.withSerialQueries(caches: caches) {
            try forward(caches, count: width)
        }
        eval([result] + CBv2OwnedRectangularAttention.stagingRoots(rows: state.rows.map { $0! }))
        try owner.check()
        for row in state.rows { row!.rollback(width - keep); row!.commitSpeculativeWrite() }
        state.bank.invalidateBoundComposition()
        let rebound = state.bank.layerCaches(rowStates: [state.rows])
        eval(rebound.flatMap { ($0 as! any KVCache).innerState() }); try owner.check()
        return try CBv2OwnedStateSnapshot.capture(geometry: state.geometry, rows: state.rows,
            recurrent: state.recurrent, committedTokens: base + keep,
            globalLayerIndices: WindowedStateFixtureModel.globals, includeBytes: true, check: owner.check)
    }
}
#endif
