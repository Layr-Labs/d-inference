// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

@Suite("Loop guard: the decision per served model type")
struct GenerationLoopGuardDecisionTests {
    private typealias Exit = GenerationLoopExitThinkingPolicy

    /// Each served type's decision: its guard, then its exit from a repeating thought.
    private static let pinned: [ServedModelType: String] = [
        .gemma4: "guarded, exit on",
        .gemma4Text: "guarded, exit on",
        .gptOSS: "guarded, exit on",
        .qwen35: "guarded, exit on proven builds",
        .qwen35MoE: "guarded, exit on proven builds",
        .nemotronHOmni: "guarded, exit opt-in",
        .qwen4Exp: "guarded, keeps length",
        .qwen4ExpText: "guarded, keeps length",
        .nemotronH: "guarded, keeps length",
        .glm5Next: "guarded, keeps length",
        .mimoV2: "guarded, keeps length",
        .diffusionGemma: "unguarded",
        .flint: "unguarded",
        .prismHadamardQwen35: "unguarded",
        .qwen3VLMoE: "unguarded",
    ]

    private static func summary(_ decision: GenerationLoopGuardPolicy.Decision) -> String {
        switch decision {
        case .guarded(.on): "guarded, exit on"
        case .guarded(.provenBuilds): "guarded, exit on proven builds"
        case .guarded(.optIn): "guarded, exit opt-in"
        case .guarded(.keepsLength): "guarded, keeps length"
        case .unguarded: "unguarded"
        }
    }

    @Test("every served model type has the decision pinned here, with a reason where it has no guard or no exit")
    func everyServedTypeIsDecided() {
        #expect(Set(Self.pinned.keys) == Set(ServedModelType.allCases))
        for type in ServedModelType.allCases {
            let decision = GenerationLoopGuardPolicy.decision(type)
            #expect(Self.summary(decision) == Self.pinned[type], "\(type)")
            switch decision {
            case .guarded(.keepsLength(let reason)), .unguarded(let reason):
                #expect(!reason.isEmpty, "\(type)")
            case .guarded(.provenBuilds(_, let ids)):
                // Without a proven build the exit would take every build (`keepsLength`).
                #expect(!ids.isEmpty, "\(type)")
            case .guarded(.on), .guarded(.optIn):
                break
            }
        }
    }

    /// Spelled out here, not read from the policy, so a change to a decision
    /// that moves a model type in or out of a list shows up as a diff of this
    /// test.
    @Test("the default lists hold exactly these model types, markers and proven builds")
    func defaultListsArePinned() {
        #expect(GenerationLoopGuardPolicy.defaultModelTypes == [
            "gemma4", "gemma4_text", "qwen3_5", "qwen3_5_moe", "qwen4_exp", "qwen4_exp_text", "gpt_oss",
            "nemotron_h", "nemotron_h_omni", "glm5_next", "mimo_v2",
        ])
        #expect(Exit.defaultModelTypes == ["gemma4", "gemma4_text", "gpt_oss", "qwen3_5", "qwen3_5_moe"])
        let gemma = Exit.Markers(open: "<|channel>", close: "<channel|>")
        let qwen = Exit.Markers(open: "<think>", close: "</think>", before: "\n", after: "\n\n")
        #expect(Exit.markersByModelType == [
            "gpt_oss": Exit.Markers(
                open: "<|channel|>analysis", close: "<|end|>", after: "<|start|>assistant", controls: ["<|start|>"]),
            "gemma4": gemma, "gemma4_text": gemma,
            "qwen3_5": qwen, "qwen3_5_moe": qwen,
            "nemotron_h_omni": Exit.Markers(open: "<think>", close: "</think>"),
        ])
        #expect(Exit.provenBuilds == [
            "Qwen3.5-9B": "qwen3_5",
            "qwen3.5-35b-a3b": "qwen3_5_moe",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8": "qwen3_5_moe",
        ])
    }
}
