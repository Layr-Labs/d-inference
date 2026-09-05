// Copyright © 2026 Eigen Labs.
//
// Gemma 4's load-time optimization report — the one family-specific
// diagnostic the provider still emits, kept in a file its name announces.
//
// It is telemetry about kernel routing (the layer-18 chunk interval, the
// weighted expert unsort, the safe-R1 expert-tile path), not part of engine
// construction: the serving path asks for it once at slot build and never
// again. `forServingModel` returns nil for every other family, so no caller
// branches on a model type.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

enum GemmaOptimizationReason: String, Sendable, Equatable {
    case disabled
    case modelIneligible = "model_ineligible"
    case aotUnavailable = "aot_unavailable"
    case naxPrecedence = "nax_precedence"
    case effective
}

struct GemmaOptimizationState: Sendable, Equatable {
    let name: String
    let requested: Bool
    let effective: Bool
    let reason: GemmaOptimizationReason

    var compactDescription: String {
        "\(name)(requested=\(requested),effective=\(effective),reason=\(reason.rawValue))"
    }
}

/// Pure requested/effective resolution for the three retained Gemma controls.
/// Safe R1 is inferred from one unarmed device snapshot; this type never
/// resets, arms, or samples route counters.
struct GemmaOptimizationReport: Sendable, Equatable {
    let layer18: GemmaOptimizationState
    let weightedUnsort: GemmaOptimizationState
    let safeR1: GemmaOptimizationState

    init(
        layer18Requested: Bool,
        layer18Effective: Bool,
        weightedUnsortRequested: Bool,
        weightedUnsortEffective: Bool,
        safeR1Requested: Bool,
        safeR1GeometryEligible: Bool,
        safeR1AOTAvailable: Bool,
        safeR1NAXAvailable: Bool
    ) {
        layer18 = Self.resolve(
            name: "layer18",
            requested: layer18Requested,
            modelEligible: layer18Effective)
        weightedUnsort = Self.resolve(
            name: "weighted_unsort",
            requested: weightedUnsortRequested,
            modelEligible: weightedUnsortEffective)
        safeR1 = Self.resolve(
            name: "safe_r1",
            requested: safeR1Requested,
            modelEligible: safeR1GeometryEligible,
            aotAvailable: safeR1AOTAvailable,
            naxAvailable: safeR1NAXAvailable)
    }

    var states: [GemmaOptimizationState] {
        [layer18, weightedUnsort, safeR1]
    }

    func logLine(modelId: String) -> String {
        "engine_v2: \(modelId) gemma optimizations "
            + states.map(\.compactDescription).joined(separator: " ")
    }

    func telemetryEvents(modelId: String) -> [TelemetryEvent] {
        states.map { state in
            var event = TelemetryEvent(
                source: .provider,
                severity: .info,
                kind: .engineHealth,
                message: "engine_v2: gemma optimization "
                    + state.compactDescription)
            event.fields = TelemetryFieldFilter.filter([
                "component": .string("engine"),
                "operation": .string("gemma_optimization_\(state.name)"),
                "backend": .string("engine_v2"),
                "model": .string(modelId),
                // Existing allowlisted field, carrying the bounded 2-bit
                // requested/effective state without a telemetry schema change.
                "target": .string(
                    "requested_\(state.requested ? 1 : 0)_effective_"
                        + "\(state.effective ? 1 : 0)"),
                "reason": .string(state.reason.rawValue),
            ])
            return event
        }
    }

    private static func resolve(
        name: String,
        requested: Bool,
        modelEligible: Bool,
        aotAvailable: Bool? = nil,
        naxAvailable: Bool = false
    ) -> GemmaOptimizationState {
        let reason: GemmaOptimizationReason
        if !requested {
            reason = .disabled
        } else if !modelEligible {
            reason = .modelIneligible
        } else if aotAvailable == false {
            reason = .aotUnavailable
        } else if naxAvailable {
            reason = .naxPrecedence
        } else {
            reason = .effective
        }
        return GemmaOptimizationState(
            name: name,
            requested: requested,
            effective: reason == .effective,
            reason: reason)
    }
}

extension GemmaOptimizationReport {
    /// One load-time snapshot for a Gemma 4 text tower, or nil for any other
    /// serving model. Reads device diagnostics without arming the benchmark
    /// counters — the QMM hot path stays free of counter atomics.
    static func forServingModel(_ model: any LanguageModel) -> GemmaOptimizationReport? {
        guard let gemmaModel = model as? Gemma4TextModel else { return nil }
        let r1 = GPU.gemma4ExpertQMMDiagnostics()
        let layerInterval = gemmaModel.cbv2PrefillChunkEvalInterval
        return GemmaOptimizationReport(
            layer18Requested: layerInterval > 0,
            layer18Effective:
                layerInterval > 0
                && gemmaModel.cbv2LayerKinds.count >= layerInterval,
            weightedUnsortRequested: gemmaModel.weightedExpertUnsortRequested,
            weightedUnsortEffective: gemmaModel.weightedExpertUnsortEffective,
            safeR1Requested: r1.requested,
            safeR1GeometryEligible: gemmaModel.expertQMMGeometryEligible,
            safeR1AOTAvailable: r1.aotAvailable,
            safeR1NAXAvailable: r1.naxAvailable)
    }
}
