// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Muse Glimmer reasoning strength")
struct MuseGlimmerReasoningStrengthTests {
    private static let modelType = MuseGlimmerModelPolicy.modelType

    /// The template context the production pipeline builds for a body.
    private func context(_ controls: [String: Any]) throws -> [String: any Sendable] {
        var body: [String: Any] = [
            "model": MuseGlimmerModelPolicy.catalogModelID,
            "messages": [["role": "user", "content": "hi"]],
            "_darkbloom_prompt_date": "2026-11-13",
        ]
        body.merge(controls) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = try ProviderLoop.decodeOpenAIRequest(data, modelType: Self.modelType)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: Self.modelType)
        return try ProviderPromptContractPipeline.normalizedInput(
            prepared: prepared, request: request, modelType: Self.modelType,
            templateControls: ProviderLoop.extractChatTemplateControls(from: data)).additionalContext ?? [:]
    }

    @Test("each effort renders the template's reasoning strength")
    func effortTable() throws {
        let expected: [(ReasoningEffort, String)] = [
            (.none, "low"), (.minimal, "low"), (.low, "low"), (.medium, "medium"),
            (.high, "high"), (.xhigh, "xhigh"), (.max, "xhigh")]
        #expect(expected.map(\.0) == ReasoningEffort.allCases)
        for (effort, strength) in expected {
            #expect(effort.museGlimmerStrength.rawValue == strength)
            for controls in [["reasoning_effort": effort.rawValue], ["reasoning": ["effort": effort.rawValue]]]
                as [[String: Any]] {
                let context = try context(controls)
                #expect(context["reasoning_strength"] as? String == strength)
                // The template reads neither; they are not part of its context.
                #expect(context["reasoning_effort"] == nil && context["enable_thinking"] == nil)
            }
        }
        #expect(ReasoningEffortPolicy.reasons(modelID: "any/model", modelType: Self.modelType))
    }

    @Test("no effort keeps the template's default; a thinking switch set to off selects low")
    func switches() throws {
        #expect(try context([:])["reasoning_strength"] == nil)
        #expect(try context(["reasoning": ["enabled": true]])["reasoning_strength"] == nil)
        #expect(try context(["enable_thinking": true, "reasoning_effort": "medium"])["reasoning_strength"]
            as? String == "medium")
        for off in [["reasoning": ["enabled": false]], ["enable_thinking": false],
                    ["chat_template_kwargs": ["enable_thinking": false]],
                    ["reasoning": ["enabled": false, "effort": "xhigh"]],
                    ["enable_thinking": false, "reasoning_effort": "high"]] as [[String: Any]] {
            #expect(try context(off)["reasoning_strength"] as? String == "low")
        }
        // The typed nested switch wins over the raw alias.
        #expect(try context(["reasoning": ["enabled": true], "enable_thinking": false])["reasoning_strength"] == nil)
    }

    @Test("an effort that is none of the names is refused, naming its field")
    func unknownEffort() throws {
        for (controls, field) in [(["reasoning_effort": "turbo"], ReasoningEffortField.reasoningEffort),
                                  (["reasoning": ["effort": "turbo"]], .reasoningObject)]
            as [([String: Any], ReasoningEffortField)] {
            do {
                _ = try context(controls)
                Issue.record("accepted \(controls)")
            } catch MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(let refused) {
                #expect(refused == field)
            }
        }
    }

    @Test("the request date reaches the template and nothing else does")
    func requestDate() throws {
        let context = try context(["reasoning_effort": "high"])
        #expect(Set(context.keys) == ["reasoning_strength", "_darkbloom_request_clock"])
    }
}
