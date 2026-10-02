#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX
import MLXLMCommon

enum WindowedStateFailureCheck {
    static func require(_ value: Bool, _ message: String) throws {
        try WindowedStateFixtureOwner.require(value, message)
    }

    static func run(check: @escaping () throws -> Void) throws -> [String] {
        var passed: [String] = []
        for fault in ["row-identity", "device-position", "native-dtype", "descriptor-shape", "descriptor-window",
                      "lost-history", "pending-window-write", "output-validation", "chunk-bound"] {
            weak var full: AnyObject?, window: AnyObject?
            try autoreleasepool {
                let owner = try WindowedStateFixtureOwner(check: check, alterLayout: { layout in
                    guard fault == "descriptor-shape" || fault == "descriptor-window" else { return layout }
                    let layers = layout.layers.enumerated().map { index, layer in
                        LayerAttentionStateLayout.Layer(globalIndex: layer.globalIndex, kvHeads: layer.kvHeads,
                            headDimension: fault == "descriptor-shape" && index == 1 ? 32 : layer.headDimension,
                            window: fault == "descriptor-window" && index == 1 ? 5 : layer.window, element: layer.element)
                    }
                    return try .init(layers: layers, maximumTokens: layout.maximumTokens, maximumChunkTokens: layout.maximumChunkTokens)
                })
                defer { try? owner.close() }
                full = owner.state.rows[0]; window = owner.state.rows[1]
                if fault == "lost-history" || fault == "pending-window-write" {
                    try owner.advance(5)
                    let row = owner.state.rows[1] as! CBv2WindowedSequenceKV
                    if fault == "lost-history" {
                        // Actual destructive writes followed by rollback lose
                        // two old slots, while the absolute frontier returns to 5.
                        let kind = WindowedStateFixtureModel.kinds[1]
                        _ = row.update(keys: WindowedStateFixtureModel.tensor(kind: kind, start: 5, count: 2, dtype: .float32, values: false),
                            values: WindowedStateFixtureModel.tensor(kind: kind, start: 5, count: 2, dtype: .float32, values: true))
                        row.rollback(2)
                        try require(row.absoluteOffset == 5 && row.retainedCount == 2, "Lost-history fixture did not actually destroy old slots")
                    } else { row.beginSpeculativeWrite() }
                }
                var refused = false
                do {
                    try owner.advance(fault == "chunk-bound" ? 8 : 1,
                        dtypes: fault == "native-dtype" ? [.float32, .float32] : WindowedStateFixtureModel.dtypes,
                        afterEvaluation: {
                            if fault == "row-identity" {
                                owner.state.geometry.caches[1].setRows([CBv2WindowedSequenceKV(window: 4, kvHeads: 2, headDim: 64)])
                            } else if fault == "device-position" {
                                owner.state.geometry.caches[1].positionOffsets._updateInternal(MLXArray([Int32(0)]))
                            } else if fault == "output-validation" {
                                throw ProbeError("Injected fixture output validation failure")
                            }
                        })
                } catch {
                    let expected: String
                    switch fault {
                    case "row-identity", "device-position": expected = "Attention cache lost its owned row or absolute device position"
                    case "native-dtype", "descriptor-shape": expected = "Attention physical geometry/type differs from observation"
                    case "descriptor-window", "lost-history", "pending-window-write": expected = "Attention logical chronology/window differs from committed frontier"
                    case "chunk-bound": expected = "CBv2 state advance exceeds the admitted capacity"
                    default: expected = "Injected fixture output validation failure"
                    }
                    guard let error = error as? ProbeError, error.description == expected else { throw error }
                    refused = true
                }
                try require(refused && owner.state.isFailed && owner.state.isClosed, "Fault did not retire the actual request owner")
                try owner.close()
            }
            try require(full == nil && window == nil, "Failed request retained native row ownership")
            passed.append("actual-refusal-and-retirement-" + fault)
        }
        try cancelled(check: check)
        passed.append("actual-post-evaluation-cancellation-retirement")
        return passed
    }

    static func cancelled(check: @escaping () throws -> Void) throws {
        var cancelled = false
        let owner = try WindowedStateFixtureOwner(check: {
            try check()
            if cancelled { throw ProbeError("Injected fixture cancellation") }
        })
        defer { try? owner.state.retire(failed: true) }
        var refused = false
        do { try owner.advance(1, afterEvaluation: { cancelled = true }) }
        catch {
            guard let error = error as? ProbeError, error.description == "Injected fixture cancellation" else { throw error }
            refused = true
        }
        try require(refused && owner.state.isClosed && owner.state.isFailed && owner.state.committedTokens == 0
            && owner.state.rows.isEmpty && owner.state.backend.bytesReserved == 0,
            "Cancellation committed or retained provisional state")
        cancelled = false
        try owner.close()
    }
}
#endif
