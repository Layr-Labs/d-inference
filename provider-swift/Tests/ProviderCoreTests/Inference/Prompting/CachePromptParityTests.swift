import Foundation
import Testing
@testable import ProviderCore

@Suite("Cache prompt thinking parity")
struct CachePromptParityTests {
    @Test("sidecar and provider share native reasoning context and fail-closed controls")
    func nativeReasoningContextVectors() throws {
        let url = try vectorFile("native_reasoning_vectors.json")
        let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(cases.count == 25)
        for fixture in cases {
            let body = try JSONSerialization.data(withJSONObject: #require(fixture["request"]))
            do {
                let request = try ProviderLoop.decodeOpenAIRequest(body)
                let prepared = try ToolChoicePromptPolicy.prepare(request)
                let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                    for: request, controls: ProviderLoop.extractChatTemplateControls(from: body),
                    modelType: fixture["model_type"] as? String,
                    requiresToolCall: prepared.requiresToolCall) ?? [:]
                try Qwen4SupportPolicy.validateReasoningContext(
                    modelID: request.model, modelType: fixture["model_type"] as? String,
                    additionalContext: context)
                #expect(fixture["error"] as? Bool != true)
                let actual = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: context))
                let expected = try #require(fixture["additional_context"] as? [String: Any])
                #expect((actual as? NSDictionary)?.isEqual(to: expected) == true)
            } catch {
                #expect(fixture["error"] as? Bool == true)
            }
        }
    }

    @Test("sidecar and provider share exact parallel tool forcing instructions")
    func parallelToolInstructionVectors() throws {
        let url = try vectorFile("tool_choice_parallel_vectors.json")
        let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(cases.count == 16)
        for fixture in cases {
            let names = try #require(fixture["tool_names"] as? [String])
            var requestObject: [String: Any] = [
                "model": "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp",
                "reasoning": ["enabled": true, "effort": "low"],
                "messages": [
                    ["role": "system", "content": "System policy."],
                    ["role": "user", "content": "Please look up the independent requests."],
                ],
                "tools": names.map { name -> [String: Any] in
                    ["type": "function", "function": [
                        "name": name, "parameters": ["type": "object", "properties": [:]],
                    ]]
                },
                "tool_choice": try #require(fixture["tool_choice"]),
            ]
            if let parallel = fixture["parallel_tool_calls"] {
                requestObject["parallel_tool_calls"] = parallel
            }
            let request = try ProviderLoop.decodeOpenAIRequest(
                JSONSerialization.data(withJSONObject: requestObject))
            let prepared = try ToolChoicePromptPolicy.prepare(request)
            let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: .init(), modelType: "qwen4_exp",
                requiresToolCall: prepared.requiresToolCall)
            #expect(context?["enable_thinking"] as? Bool == true)
            #expect(context?["reasoning_effort"] as? String == "low")
            let instruction = fixture["expected_instruction"] as? String
            let expectedSystem = "System policy." + (instruction.map { "\n\n" + $0 } ?? "")
            let expectedUser = "Please look up the independent requests."
                + ((fixture["repeat_user"] as? Bool == true) ? "\n\n" + (instruction ?? "") : "")
            #expect(prepared.messages.count == 2)
            #expect(prepared.messages[0].textContent == expectedSystem)
            #expect(prepared.messages[1].textContent == expectedUser)
            #expect((prepared.tools ?? []).map(\.function.name) == fixture["expected_tool_names"] as? [String])
        }
    }

    @Test("sidecar and provider share required-tool thinking precedence across catalog aliases")
    func forcedToolThinkingVectors() throws {
        let url = try vectorFile("forced_tool_thinking_vectors.json")
        let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(cases.count == 18)
        for fixture in cases {
            let body = try JSONSerialization.data(withJSONObject: #require(fixture["request"]))
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            let prepared = try ToolChoicePromptPolicy.prepare(request)
            let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: ProviderLoop.extractChatTemplateControls(from: body),
                modelType: fixture["model_type"] as? String,
                requiresToolCall: prepared.requiresToolCall)
            #expect(context?["enable_thinking"] as? Bool == fixture["enable_thinking"] as? Bool)
            #expect(context?["preserve_thinking"] as? Bool == true)
        }
    }

    /// Resolve the owning repository, not a fixed number of parent folders.
    /// These tests move with their subsystem; the shared fixtures do not.
    private func vectorFile(_ name: String) throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = FileManager.default
        while root != root.deletingLastPathComponent() {
            if files.fileExists(atPath: root.appendingPathComponent("provider-swift/Package.swift").path),
               files.fileExists(atPath: root.appendingPathComponent("go.mod").path) {
                return root.appendingPathComponent("fixtures/prompt-contract/v1").appendingPathComponent(name)
            }
            root.deleteLastPathComponent()
        }
        throw FixtureLocationError.repositoryRootNotFound
    }

    private enum FixtureLocationError: Error { case repositoryRootNotFound }
}
