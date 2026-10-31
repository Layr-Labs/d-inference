import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// CBv2 owned-state contract coverage that requires no model: phase observation
// semantics, the geometry refusal boundary, and pinned-build capability
// discovery. A full owned-state run/snapshot/poison test requires the
// authorized Qwen3.5 fixture model and is recorded as blocked (hardware/model
// authorization), not simulated.

@Suite("CBv2 owned state contract (no model)")
struct CBv2OwnedStateContractTests {
    @Test func phaseObservationPreservesPendingErrors() throws {
        // Exact diagnostic identities: these strings are a mirrored contract.
        #expect(CBv2OwnerPhase.graphConstructionBegin.rawValue == "graphConstruction.begin")
        #expect(CBv2OwnerPhase.evaluationEnd.rawValue == "evaluation.end")
        #expect(CBv2OwnerPhase.validationCommitEnd.rawValue == "validationCommit.end")
        #expect(CBv2OwnerPhase.allCases.count == 8)
        let observation = CBv2OwnerPhaseObservation(phase: .evaluationBegin, tokenCount: 4, committedTokens: 12)
        #expect(observation.tokenCount == 4 && observation.committedTokens == 12)
        // A successful observation introduces no extra check.
        var checks = 0
        try observation.deliver(to: { _ in }, check: { checks += 1 })
        #expect(checks == 0)
        // A throwing observer runs the pending check before rethrowing. When
        // the check passes, the observation error is thrown; when the check
        // itself fails, the pending native/deadline error wins by design —
        // the observation must never mask it (see the deliver() contract).
        struct ObservationError: Error {}
        struct PendingError: Error {}
        var pendingRan = 0
        #expect(throws: ObservationError.self) {
            try observation.deliver(to: { _ in throw ObservationError() }, check: { pendingRan += 1 })
        }
        #expect(pendingRan == 1)
        pendingRan = 0
        #expect(throws: PendingError.self) {
            try observation.deliver(to: { _ in throw ObservationError() }, check: {
                pendingRan += 1
                throw PendingError()
            })
        }
        #expect(pendingRan == 1)
    }

    @Test func geometryConfigurationGateIsStrict() throws {
        // The model-facing geometry init additionally requires a concrete
        // pinned Qwen model instance; that refusal boundary is type-level
        // (`any LanguageModel` + runtime protocol conformance checks) and is
        // covered by the capability test below. Its configuration gate is
        // directly testable: explicit positive integers only, never booleans,
        // strings, missing keys, or overflow-sized values.
        #expect(try qwenPartitionInteger(["max_position_embeddings": 32_768], "max_position_embeddings") == 32_768)
        #expect(try qwenPartitionInteger(["sliding_window": 0], "sliding_window", allowZero: true) == 0)
        #expect(throws: ProbeError.self) { _ = try qwenPartitionInteger([:], "max_position_embeddings") }
        #expect(throws: ProbeError.self) { _ = try qwenPartitionInteger(["max_position_embeddings": "32768"], "max_position_embeddings") }
        #expect(throws: ProbeError.self) { _ = try qwenPartitionInteger(["max_position_embeddings": true], "max_position_embeddings") }
        #expect(throws: ProbeError.self) { _ = try qwenPartitionInteger(["max_position_embeddings": 0], "max_position_embeddings") }
        #expect(throws: ProbeError.self) { _ = try qwenPartitionInteger(["max_position_embeddings": 1_048_577], "max_position_embeddings") }
    }

    @Test func pinnedBuildExposesRequiredCBv2Surface() throws {
        // Capability discovery against the pinned Darkbloom MLX build, not
        // documentation: the exact types the runtime depends on must resolve.
        // (Group creation, device collectives and JACCL are NOT exercised.)
        #expect(InferenceModelFamily.qwen35.rawValue == "qwen35")
        _ = Qwen35TextModel.self
        _ = Qwen35Model.self
        _ = CBv2LayerCache.self
        _ = CBv2ContiguousKVBackend.self
        _ = CBv2RecurrentStateSpec.self
        _ = CBv2SequenceKV.self
        _ = CBv2RecurrentRequestState.self
        _ = CBv2LayerCacheBank.self
    }
}
