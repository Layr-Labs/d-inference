#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX
import MLXLMCommon

/// The test driver supplies only fixed geometry. State, evaluation and retirement
/// are the real shared owner; no substitute backend or cache implementation.
final class WindowedStateFixtureOwner {
    let state: CBv2OwnedRequestState
    let check: () throws -> Void
    let constant: Bool

    init(check: @escaping () throws -> Void, constant: Bool = false,
         alterLayout: ((LayerAttentionStateLayout) throws -> LayerAttentionStateLayout)? = nil) throws {
        self.check = check; self.constant = constant
        var geometry = try WindowedStateFixtureModel.geometry(check: check)
        if let alterLayout { geometry.attentionLayout = try alterLayout(geometry.attentionLayout!) }
        try check()
        state = try .init(geometry: geometry, promptCount: 2, outputCount: 30)
    }

    func advance(_ count: Int, dtypes: [DType] = WindowedStateFixtureModel.dtypes,
                 afterEvaluation: (() throws -> Void)? = nil) throws {
        do {
            try check()
            _ = try state.run(tokenCount: count, check: check, forward: { caches, _ in
                try self.check()
                return try WindowedStateFixtureModel.forward(caches: caches, count: count,
                    dtypes: dtypes, constant: self.constant)
            }, validateOutput: { output in
                guard output.size == 1, output.dtype == .float32, output.item(Float.self).isFinite else {
                    throw ProbeError("Fixture attention result is not a finite scalar")
                }
                try afterEvaluation?()
            })
            try check()
        } catch {
            try state.retire(failed: true)
            throw error
        }
    }

    func snapshot() throws -> CBv2OwnedStateSnapshot {
        try check()
        return try state.snapshot(globalLayerIndices: state.geometry.attentionLayout!.layers.map(\.globalIndex),
            includeBytes: true, check: check)
    }

    func close(failed: Bool = false) throws {
        try state.retire(failed: failed)
        try Self.require(state.isClosed && state.rows.isEmpty && state.backend.bytesInUse == 0
            && state.backend.bytesReserved == 0 && state.geometry.caches.allSatisfy({ $0.rows.isEmpty })
            && state.recurrent.isReleased && state.recurrent.materializedByteCount == 0,
            "Fixture retained actual state after retirement")
        try check()
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw ProbeError(message) }
    }

    deinit { if !state.isClosed { try? state.retire(failed: true) } }
}
#endif
