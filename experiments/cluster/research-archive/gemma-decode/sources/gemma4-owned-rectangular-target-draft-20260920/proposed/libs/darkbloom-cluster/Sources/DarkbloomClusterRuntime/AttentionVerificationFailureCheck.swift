#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX
import MLXLMCommon

enum AttentionVerificationFailureCheck {
    enum Injected: Error { case refused }
    static func refuses(_ body: () throws -> Void) throws {
        var refused = false
        do { try body() } catch { refused = true }
        try AttentionVerificationFixture.require(refused, "Invalid attention transaction was accepted")
    }
    static func run(check: @escaping () throws -> Void) throws -> [String] {
        for mode in ["no-admission", "width-overrun", "wrong-forward-width", "partial-forward",
                     "cancel-after-forward", "invalid-prefix", "replayed-stage", "ordinary-during-stage",
                     "reentrant-stage", "reentrant-admission"] {
            try autoreleasepool {
                let owner = try WindowedStateFixtureOwner(check: check)
                defer { try? owner.close(failed: true) }
                try owner.advance(7)
                weak var full: AnyObject? = owner.state.rows[0]
                weak var window: AnyObject? = owner.state.rows[1]
                try refuses {
                    if mode == "no-admission" {
                        try owner.state.beginAttentionVerification(steps: 4, captureLayerIndices: [0, 1],
                            admit: { _ in throw Injected.refused }, check: check)
                        return
                    }
                    if mode == "width-overrun" {
                        try AttentionVerificationFixture.begin(owner, width: 5); return
                    }
                    if mode == "reentrant-admission" {
                        try owner.state.beginAttentionVerification(steps: 4, captureLayerIndices: [],
                            admit: { _ in try owner.state.requireOpen() }, check: check)
                        return
                    }
                    try AttentionVerificationFixture.begin(owner, width: 4)
                    if mode == "ordinary-during-stage" { try owner.state.requireOpen(); return }
                    if mode == "wrong-forward-width" {
                        _ = try owner.state.stageAttentionVerification(check: check, additionalTargets: { [] },
                            forward: { try AttentionVerificationFixture.forward($0, count: 3) },
                            validateOutput: { _ in })
                        return
                    }
                    if mode == "partial-forward" {
                        _ = try owner.state.stageAttentionVerification(check: check, additionalTargets: { [] },
                            forward: { caches in
                                _ = try AttentionVerificationFixture.forward(caches, count: 4, layers: 1)
                                throw Injected.refused
                            }, validateOutput: { _ in })
                        return
                    }
                    if mode == "cancel-after-forward" {
                        var constructed = false
                        _ = try owner.state.stageAttentionVerification(check: {
                            try check(); if constructed { throw Injected.refused }
                        }, additionalTargets: { [] }, forward: { caches in
                            let output = try AttentionVerificationFixture.forward(caches, count: 4)
                            constructed = true; return output
                        }, validateOutput: { _ in })
                        return
                    }
                    if mode == "reentrant-stage" {
                        _ = try owner.state.stageAttentionVerification(check: check, additionalTargets: { [] },
                            forward: { _ in try AttentionVerificationFixture.stage(owner, width: 4) },
                            validateOutput: { _ in })
                        return
                    }
                    _ = try AttentionVerificationFixture.stage(owner, width: 4)
                    if mode == "replayed-stage" { _ = try AttentionVerificationFixture.stage(owner, width: 4); return }
                    _ = try owner.state.reconcileAttentionVerification(keeping: 5, check: check)
                }
                try AttentionVerificationFixture.require(owner.state.committedTokens == 7,
                    "Refused transaction published speculative frontier")
                try owner.close(failed: true)
                try AttentionVerificationFixture.require(full == nil && window == nil
                    && owner.state.backend.bytesCapacity == owner.state.geometry.kvCapacityBytes,
                    "Failed transaction retained capture, row or temporary capacity")
            }
        }
        return ["admission-refusal-before-staging", "width-and-forward-coverage-refusals",
            "partial-forward-failure-retirement", "cancel-after-graph-retirement",
            "invalid-prefix-and-replayed-stage-refusals", "ordinary-access-blocked-during-transaction",
            "admission-and-stage-reentrancy-refused", "failed-capture-row-capacity-retirement"]
    }
}
#endif
