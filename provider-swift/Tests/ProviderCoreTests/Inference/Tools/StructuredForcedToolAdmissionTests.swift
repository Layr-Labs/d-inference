import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Qualifies the exact catalog builds admitted to required/named `tool_choice`.
/// Each case decodes an OpenRouter-shaped request and drives the production
/// forcing prompt, the parser the build resolves, the forced-mode stream router
/// and the withheld validator over scripted model output, mirroring the engine's
/// terminal order. It proves the serving contract, not model call quality.
@Suite("Structured forced tool_choice admission")
struct StructuredForcedToolAdmissionTests {
    struct Build: Sendable {
        let id: String
        let modelType: String
        /// Catalog `runtime_parameters.tool_call_parser`, forwarded by the coordinator.
        let catalogParser: String?
        let format: ToolCallFormat

        var isMiMo: Bool { modelType == "mimo_v2" }
        var info: ModelInfo { ModelInfo(id: id, modelType: modelType, sizeBytes: 1, estimatedMemoryGb: 1) }
    }

    static let admitted: [Build] = [
        Build(id: "Qwen3.5-9B", modelType: "qwen3_5", catalogParser: "qwen3_5", format: .qwen35),
        Build(id: "qwen3.5-35b-a3b", modelType: "qwen3_5_moe", catalogParser: nil, format: .qwen35),
        Build(id: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: "qwen3_5_moe", catalogParser: nil, format: .qwen35),
        Build(id: "mimo-v2.6-flash-mopd", modelType: "mimo_v2", catalogParser: nil, format: .mimoV2),
    ]

    /// Already advertised before this admission; kept under the same invariant.
    static let qwen38: [Build] = ModelRuntimeRequirements.qwen38ConcreteModelIDs.sorted().map {
        Build(id: $0, modelType: "qwen3_5", catalogParser: "qwen3_5", format: .qwen35)
    }

    private static let required = "required"
    private static var namedWeather: [String: Any] {
        ["type": "function", "function": ["name": "get_weather"]]
    }

    private static var tools: [[String: Any]] {
        [
            ["type": "function", "function": [
                "name": "get_weather",
                "description": "Get the current weather for a city",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "city": ["type": "string"],
                        "unit": ["type": "string", "enum": ["c", "f"]],
                    ],
                    "required": ["city"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any]],
            ["type": "function", "function": [
                "name": "get_time",
                "parameters": [
                    "type": "object",
                    "properties": ["timezone": ["type": "string"]],
                    "required": ["timezone"],
                ] as [String: Any],
            ] as [String: Any]],
        ]
    }

    // MARK: - Advertisement

    @Test func registrationAndUpdateAdvertiseExactlyTheAdmittedBuilds() throws {
        let admitted = Self.admitted.map(\.info)
        let refused = [
            // A catalog ID on another architecture is not the qualified artifact:
            // its parser or forcing path differs.
            info("Qwen3.5-9B", "qwen3_5_moe"), info("Qwen3.5-9B", nil), info("Qwen3.5-9B", "llama"),
            info("qwen3.5-35b-a3b", "qwen3_5"), info("qwen3.6-35b-a3b-vl-mtp-mxfp8", "qwen3_vl_moe"),
            info("mimo-v2.6-flash-mopd", "qwen3_5"),
            // Lookalike IDs of the admitted families.
            info("Qwen3.5-27B", "qwen3_5"), info("qwen3.6-35b-a3b", "qwen3_5_moe"),
            info("mimo-v2.6-flash", "mimo_v2"), info("EigenLabs/MiMo-V2.6-Flash-MOPD-MLX-4bit-mtp", "mimo_v2"),
            // Harmony has no forced strategy.
            info("gpt-oss-20b", "gpt_oss"), info("openai-gpt-oss-20b", "gpt_oss"),
        ]
        let expected = admitted.map(\.id).sorted()

        let registration = try register(admitted + refused)
        #expect(registration.toolConstraintProtocol == 1)
        #expect(registration.toolConstraintModels == expected)

        let update = try modelsUpdate(admitted + refused)
        #expect(update.toolConstraintProtocol == 1)
        #expect(update.toolConstraintModels == expected)

        // Replacing an admitted build by another architecture revokes it in the
        // next authoritative update instead of leaving a stale positive claim.
        let revoked = try modelsUpdate([info("Qwen3.5-9B", "llama")] + refused)
        #expect(revoked.toolConstraintModels == [])
    }

    /// Advertising a build that the serving path then refuses was the Qwen3.8
    /// failure fixed by #1527. Every advertised structured build must accept
    /// both forced modes with each parser its catalog entry can supply.
    @Test func everyAdvertisedStructuredBuildServesBothForcedModes() throws {
        for build in Self.admitted + Self.qwen38 {
            #expect(ToolChoiceEnforcementPolicy.advertisesCapability(for: build.info), "\(build.id)")
            for parser in Set([build.catalogParser, nil]) {
                for choice in [Self.required, Self.namedWeather] as [Any] {
                    let request = try request(build, choice: choice, parser: parser)
                    let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: build.modelType)
                    #expect(prepared.requiresToolCall)
                    #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(
                        mode: prepared.mode,
                        modelContext: .init(modelId: build.id, modelType: build.modelType))
                        == .structuredPostValidation)
                    let handler = try #require(try ToolStreamPreparation.makeHandler(
                        request: request, prepared: prepared, modelType: build.modelType))
                    #expect(handler.format == build.format, "\(build.id) parser \(parser ?? "inferred")")
                    #expect(!handler.streamsCalls, "forced calls stay withheld until validated")
                }
            }
        }
    }

    @Test func harmonyStaysUnadvertisedAndRefusesForcedChoice() throws {
        let context = ChatTemplateFixContext(modelId: "gpt-oss-20b", modelType: "gpt_oss")
        #expect(!ToolChoiceEnforcementPolicy.advertisesCapability(for: info("gpt-oss-20b", "gpt_oss")))
        for mode: ToolConstraintMode in [.required, .named("get_weather")] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: context)
            }
        }
        #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .auto, modelContext: context) == .none)
    }

    // MARK: - Per-family qualification

    @Test func requiredCallsAreForcedWithheldAndValidated() throws {
        for build in Self.admitted {
            let request = try request(build, choice: Self.required)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: build.modelType)
            #expect(prepared.mode == .required)
            // Prompt-forced: the instruction renders in the system and last user turn.
            #expect(prepared.messages.first?.role == .system)
            #expect(text(prepared.messages.first).contains("a text answer is forbidden"))
            #expect(text(prepared.messages.last).hasSuffix(
                "Your entire response must consist of tool calls; a text answer is forbidden."))
            for width in [1, 7, Int.max] {
                let calls = try serve(build, request, prepared, output: answer(build, frame(build, "get_weather",
                    ["city": "Paris"])), width: width)
                #expect(calls.count == 1, "\(build.id) width \(width)")
                #expect(calls.first?.function.name == "get_weather")
                #expect(calls.first?.function.arguments["city"] == .string("Paris"))
            }
            let parallel = try serve(build, request, prepared, output: answer(build,
                frame(build, "get_weather", ["city": "Paris"]) + "\n"
                    + frame(build, "get_time", ["timezone": "Europe/Paris"])))
            #expect(parallel.map(\.function.name) == ["get_weather", "get_time"], "\(build.id)")
        }
    }

    @Test func namedCallsMustSelectTheNamedFunction() throws {
        for build in Self.admitted {
            let request = try request(build, choice: Self.namedWeather)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: build.modelType)
            #expect(prepared.mode == .named("get_weather"))
            #expect(prepared.allowedToolNames == ["get_weather"])
            #expect(text(prepared.messages.last).contains("Call the declared function 'get_weather' now."))
            let calls = try serve(build, request, prepared,
                output: answer(build, frame(build, "get_weather", ["city": "Paris", "unit": "c"])))
            #expect(calls.map(\.function.name) == ["get_weather"], "\(build.id)")
            #expect(calls.first?.function.arguments["unit"] == .string("c"))

            // A declared but unselected function is noncompliance, never exposed.
            try expectViolation(build) {
                _ = try serve(build, request, prepared,
                    output: answer(build, frame(build, "get_time", ["timezone": "UTC"])))
            }
        }
    }

    @Test func schemaInvalidArgumentsAreRefused() throws {
        for build in Self.admitted {
            for choice in [Self.required, Self.namedWeather] as [Any] {
                let request = try request(build, choice: choice)
                let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: build.modelType)
                for arguments in [["city": "Paris", "unit": "kelvin"], ["unit": "c"],
                                  ["city": "Paris", "country": "FR"]] {
                    try expectViolation(build) {
                        _ = try serve(build, request, prepared,
                            output: answer(build, frame(build, "get_weather", arguments)))
                    }
                }
            }
        }
    }

    @Test func refusalPathsFailClosed() throws {
        for build in Self.admitted {
            let request = try request(build, choice: Self.required)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: build.modelType)
            // Prose instead of a call, prose before a call, no output and an
            // undeclared function are all model noncompliance (422).
            try expectViolation(build) {
                _ = try serve(build, request, prepared, output: answer(build, "It is sunny in Paris."))
            }
            try expectViolation(build) {
                _ = try serve(build, request, prepared, output: answer(build,
                    "Let me check. " + frame(build, "get_weather", ["city": "Paris"])))
            }
            try expectViolation(build) {
                _ = try serve(build, request, prepared, output: answer(build, ""))
            }
            try expectViolation(build) {
                _ = try serve(build, request, prepared,
                    output: answer(build, frame(build, "delete_files", ["path": "/"])))
            }

            // parallel_tool_calls=false admits exactly one call.
            let single = try self.request(build, choice: Self.required, parallel: false)
            let singlePrepared = try ToolChoicePromptPolicy.prepare(single, modelType: build.modelType)
            try expectViolation(build) {
                _ = try serve(build, single, singlePrepared, output: answer(build,
                    frame(build, "get_weather", ["city": "Paris"]) + "\n"
                        + frame(build, "get_weather", ["city": "Rome"])))
            }

            // Malformed policies are client errors before any generation.
            let undeclared = try self.request(build, choice:
                ["type": "function", "function": ["name": "get_stock_price"]] as [String: Any])
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolChoicePromptPolicy.prepare(undeclared, modelType: build.modelType)
            }
            let toolless = try self.request(build, choice: Self.required, tools: [])
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolChoicePromptPolicy.prepare(toolless, modelType: build.modelType)
            }
        }
    }

    // MARK: - Helpers

    private func info(_ id: String, _ type: String?) -> ModelInfo {
        ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1)
    }

    private func request(
        _ build: Build, choice: Any, parser: String?? = .none, parallel: Bool? = nil,
        tools: [[String: Any]]? = nil
    ) throws -> OpenAIChatCompletionRequest {
        var body: [String: Any] = [
            "model": build.id,
            "messages": [["role": "user", "content": "What is the weather in Paris right now?"]],
            "tools": tools ?? Self.tools,
            "tool_choice": choice,
        ]
        if let parser = parser ?? build.catalogParser { body["tool_call_parser"] = parser }
        if let parallel { body["parallel_tool_calls"] = parallel }
        return try ProviderLoop.decodeOpenAIRequest(
            JSONSerialization.data(withJSONObject: body), modelType: build.modelType)
    }

    /// The native tool frame each family generates. MiMo values are raw bytes;
    /// Qwen 3.5 writes each element on its own line.
    private func frame(_ build: Build, _ name: String, _ arguments: [String: String]) -> String {
        let keys = arguments.keys.sorted()
        if build.isMiMo {
            return "<tool_call><function=\(name)>"
                + keys.map { "<parameter=\($0)>\(arguments[$0]!)</parameter>" }.joined()
                + "</function></tool_call>"
        }
        return "<tool_call>\n<function=\(name)>\n"
            + keys.map { "<parameter=\($0)>\n\(arguments[$0]!)\n</parameter>\n" }.joined()
            + "</function>\n</tool_call>"
    }

    /// MiMo serves forced choice with its default thinking on, so a reasoning
    /// span precedes the call; legacy Qwen renders forced calls with thinking off.
    private func answer(_ build: Build, _ content: String) -> String {
        build.isMiMo ? "<think>The user wants the current weather in Paris.</think>" + content : content
    }

    /// The engine's complete-call terminal: route text, flush the parser, check
    /// native frame failures, then validate before any call is exposed.
    private func serve(
        _ build: Build, _ request: OpenAIChatCompletionRequest, _ prepared: ToolChoicePromptPolicy.Prepared,
        output: String, width: Int = 5
    ) throws -> [ToolCall] {
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: build.modelType))
        var router = NativeToolStreamRouter(handler: handler,
            requiresToolCall: prepared.requiresToolCall,
            nativePrefix: build.isMiMo ? "" : nil,
            tools: prepared.tools?.map { $0.toolSpec() },
            nativeMiMoChannels: build.isMiMo,
            nativeMiMoRequiresConstraint: build.isMiMo && prepared.mode.requiresInferenceConstraint)
        let characters = Array(output)
        var start = 0
        while start < characters.count {
            let end = min(characters.count, start + max(1, min(width, characters.count)))
            for event in try router.process(String(characters[start..<end])) {
                guard case .parsed(let piece) = event, piece.content.isEmpty else {
                    Issue.record("\(build.id): forced output exposed before validation: \(event)")
                    continue
                }
            }
            start = end
        }
        for event in try router.finishText() {
            guard case .parsed(let piece) = event, piece.content.isEmpty else {
                Issue.record("\(build.id): forced output exposed before validation: \(event)")
                continue
            }
        }
        let calls = handler.finish()
        try router.checkNativeToolFailure()
        try ToolConstraintValidation.validate(calls, prepared: prepared)
        return calls
    }

    private func expectViolation(
        _ build: Build, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void
    ) throws {
        do {
            try body()
            Issue.record("\(build.id): expected a tool_choice violation", sourceLocation: sourceLocation)
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .toolChoiceViolation = error else {
                Issue.record("\(build.id): unexpected engine error \(error)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    private func text(_ message: OpenAIChatMessage?) -> String {
        switch message?.content {
        case .text(let text)?: return text
        case .parts(let parts)?:
            return parts.compactMap { part -> String? in
                guard case .text(let text) = part else { return nil }
                return text
            }.joined()
        case .null?, nil: return ""
        }
    }

    private func config(_ models: [ModelInfo]) -> CoordinatorClientConfig {
        CoordinatorClientConfig(url: "wss://coordinator.invalid/ws",
            hardware: HardwareInfo(machineModel: "test", chipName: "Apple M3 Ultra",
                chipFamily: .m3, chipTier: .ultra, memoryGb: 256, memoryAvailableGb: 250,
                cpuCores: CpuCores(total: 32, performance: 24, efficiency: 8),
                gpuCores: 80, memoryBandwidthGbs: 819),
            models: models, backendName: "mlx_swift_lm")
    }

    private func register(_ models: [ModelInfo]) throws -> ProviderMessage.Register {
        let bytes = try CoordinatorClientCodec.encodeRegistration(from: config(models))
        guard case .register(let result) = try ProviderProtocolCodec.decodeProviderMessage(from: bytes) else {
            throw AdmissionTestError.unexpectedMessage
        }
        return result
    }

    private func modelsUpdate(_ models: [ModelInfo]) throws -> ProviderMessage.ModelsUpdate {
        let bytes = try CoordinatorClientCodec.encodeOutboundMessage(.modelsUpdate(models: models))
        guard case .modelsUpdate(let result) = try ProviderProtocolCodec.decodeProviderMessage(from: bytes) else {
            throw AdmissionTestError.unexpectedMessage
        }
        return result
    }

    private enum AdmissionTestError: Error { case unexpectedMessage }
}
