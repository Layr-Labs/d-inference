import Foundation
import Testing
@testable import ProviderCore

@Suite("Cache prompt thinking parity")
struct CachePromptParityTests {
    @Test("sidecar and provider share native reasoning context and fail-closed controls")
    func nativeReasoningContextVectors() throws {
        let url = try vectorFile("native_reasoning_vectors.json")
        let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(cases.count == 28)
        for fixture in cases {
            let body = try JSONSerialization.data(withJSONObject: #require(fixture["request"]))
            do {
                let request = try ProviderLoop.decodeOpenAIRequest(body)
                let prepared = try ToolChoicePromptPolicy.prepare(request)
                let controls = ProviderLoop.extractChatTemplateControls(from: body)
                try ReasoningEffortPolicy.validate(request, controls: controls,
                    modelType: fixture["model_type"] as? String)
                let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                    for: request, controls: controls,
                    modelType: fixture["model_type"] as? String,
                    requiresToolCall: prepared.requiresToolCall) ?? [:]
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

    /// The coordinator maps every reasoning effort from a copy of the tables in
    /// `ReasoningEffort.swift`: its ingress refusal, its first-party pool and its
    /// prompt sidecar. `reasoning_effort_vectors.json` is their agreement test.
    /// Each set the table keeps equals the file's list, and every type that
    /// reasons has cases, so a type added or dropped on one side only fails
    /// here or in the platform's copies. Each case runs here through the
    /// production prompt pipeline
    /// (`ProviderPromptContractPipeline.tokenizeProviderBody`, or Nemotron 3.5
    /// Super's `NemotronSuperPromptContract.controls(body:)`). It must render
    /// the template-context keys the case decides (null: absent), be refused
    /// with the field it names, or fail for a contradiction.
    @Test("the coordinator and the provider map every reasoning effort alike")
    func reasoningEffortVectors() throws {
        let url = try vectorFile("reasoning_effort_vectors.json")
        let vectors = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(vectors["efforts"] as? [String] == ReasoningEffort.allCases.map(\.rawValue))
        let refusal = try #require(vectors["refusal"] as? [String: Any])
        #expect(refusal["code"] as? String == "invalid_reasoning_effort")
        for field in [ReasoningEffortField.reasoningEffort, .reasoningObject, .templateKwargs] {
            let message = (refusal["message"] as? String)?.replacingOccurrences(of: "{param}", with: field.rawValue)
            #expect(message == field.refusalMessage)
        }
        let reasoningTypes = try #require(vectors["reasoning_model_types"] as? [String])
        let qwenTemplateTypes = try #require(vectors["qwen35_template_model_types"] as? [String])
        let switchTypes = try #require(vectors["thinking_switch_model_types"] as? [String])
        let qwen38IDs = try #require(vectors["qwen38_model_ids"] as? [String])
        #expect(Set(reasoningTypes) == ReasoningEffortPolicy.reasoningModelTypes)
        #expect(Set(qwenTemplateTypes) == ReasoningEffortPolicy.qwen35TemplateTypes)
        #expect(Set(switchTypes) == ReasoningEffortPolicy.effortSwitchTypes)
        #expect(Set(qwen38IDs) == ModelRuntimeRequirements.qwen38ConcreteModelIDs)
        for type in reasoningTypes {
            #expect(ReasoningEffortPolicy.reasons(modelID: "any/model", modelType: type), "\(type)")
        }
        for type in ["qwen3_vl_moe", "llama", "gemma3"] {
            #expect(!ReasoningEffortPolicy.reasons(modelID: "any/model", modelType: type), "\(type)")
        }
        let cases = try #require(vectors["cases"] as? [[String: Any]])
        #expect(cases.count == 446)
        let asked = Set(cases.compactMap { $0["model_type"] as? String })
        #expect(ReasoningEffortPolicy.reasoningModelTypes.isSubset(of: asked),
                "types that reason without cases: \(ReasoningEffortPolicy.reasoningModelTypes.subtracting(asked))")
        for fixture in cases {
            let name = try #require(fixture["name"] as? String)
            let type = try #require(fixture["model_type"] as? String)
            let model = try #require(fixture["model"] as? String)
            let controls = try #require(fixture["controls"] as? [String: Any])
            var request: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]]]
            request.merge(controls) { _, control in control }
            let body = try JSONSerialization.data(withJSONObject: request)
            let rendered = Result { () throws -> [String: any Sendable] in
                if type == "nemotron_h_omni" {
                    let depth = try NemotronSuperPromptContract.controls(body: body)
                    return ["enable_thinking": depth.enableThinking, "medium_effort": depth.mediumEffort]
                }
                let tokenizer = EffortContextTokenizer()
                _ = try ProviderPromptContractPipeline.tokenizeProviderBody(body, tokenizer: tokenizer, modelType: type)
                return tokenizer.contexts.last ?? [:]
            }
            switch rendered {
            case .success(let context):
                #expect(fixture["refused"] == nil && fixture["error"] == nil, "\(name): rendered \(context)")
                for (key, expected) in fixture["context"] as? [String: Any] ?? [:] {
                    if expected is NSNull {
                        #expect(context[key] == nil, "\(name): \(key) = \(String(describing: context[key]))")
                    } else {
                        #expect(Self.jsonValue(context[key])?.isEqual(expected) == true,
                                "\(name): \(key) = \(String(describing: context[key])), want \(expected)")
                    }
                }
            case .failure(let error):
                let refused = Self.refusedField(error)
                if let field = fixture["refused"] as? String {
                    #expect(refused == field, "\(name): \(error)")
                } else {
                    #expect(fixture["error"] as? Bool == true && refused == nil, "\(name): \(error)")
                }
            }
        }
    }

    /// A template-context value as JSON decodes it; nil for absent or another type.
    private static func jsonValue(_ value: (any Sendable)?) -> NSObject? {
        switch value {
        case let bool as Bool: NSNumber(value: bool)
        case let string as String: string as NSString
        default: nil
        }
    }

    /// The field a refusal of an effort that is none of the names names.
    private static func refusedField(_ error: any Error) -> String? {
        if let error = error as? MultiModelBatchSchedulerEngineError,
           case .unsupportedReasoningEffort(let field) = error {
            return field.rawValue
        }
        if let failure = error as? NemotronSuperPromptContract.Failure,
           case .unknownReasoningEffort(let field) = failure {
            return field.rawValue
        }
        return nil
    }

    /// Resolve the owning repository, not a fixed number of parent folders.
    /// These tests move with their subsystem; the shared fixtures do not.
    private func vectorFile(_ name: String) throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = FileManager.default
        while root != root.deletingLastPathComponent() {
            if files.fileExists(atPath: root.appendingPathComponent("provider-swift/Package.swift").path),
               files.fileExists(atPath: root.appendingPathComponent("fixtures/prompt-contract/v1").path) {
                return root.appendingPathComponent("fixtures/prompt-contract/v1").appendingPathComponent(name)
            }
            root.deleteLastPathComponent()
        }
        throw FixtureLocationError.repositoryRootNotFound
    }

    private enum FixtureLocationError: Error { case repositoryRootNotFound }
}
