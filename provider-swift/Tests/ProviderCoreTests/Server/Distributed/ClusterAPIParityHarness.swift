import Foundation
import Hummingbird
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

// Model-free API parity harness: the SAME request against the single-Mac
// local endpoint and against the cluster's local endpoint, each over a fake
// engine that commits the SAME scripted tokens, compared byte for byte after
// removing response ids and timestamps. No model, Metal, child process or
// peer runs; this is never a hardware or model result.
//
// Single-Mac side: the product's shared HTTP builder
// (`makeLocalInferenceApplication`, exactly as `StandaloneServer` calls it)
// over an `EngineV2Bridge` built with the single-Mac slot's rules
// (`EngineV2SlotFactory`): the artifact EOS as the model loader resolves it
// plus `ModelEOSPolicy`, the artifact sampling defaults, the 4,096 default
// output, and the tokenizer handle's Gemma contract check. Its engine is a
// scripted `CBv2Engine` with the product engine's stop/length rules.
//
// Cluster side: the real `DistributedLocalServer` with its own factory
// (`DistributedEngineFactory`), the real `DistributedCBv2Engine` and the
// distributed SSE writer, over a fabricated owner whose lease commits the
// scripted tokens as a worker pair would.

// MARK: - Scripted vocabulary

/// Token id -> text piece. Ids 1...3 render every prompt.
enum ParityPieces {
    static let table: [Int: String] = [
        1: "<|im_start|>", 2: "user\nfixture", 3: "<|im_end|>\n<|im_start|>assistant\n<think>\n",
        10: "<|endoftext|>", 11: "<|im_end|>", 12: "<end_of_turn>", 13: "<eos>",
        20: "Let me think.", 21: "</think>\n\n", 22: "The answer is 4.", 23: " More.", 24: " words",
        25: " and", 26: " more", 27: "{\"answer\": 4}",
        30: "<tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>",
        31: "<TOOLCALL>[{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Paris\"}}]</TOOLCALL>",
        32: "<|tool_call>call:get_weather{city:<|\"|>Paris<|\"|>}<tool_call|>",
        40: "<|channel|>analysis<|message|>Weather needed.<|end|><|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{\"city\":\"Paris\"}",
        41: "<|call|>", 42: "<|return|>", 43: "<|endoftext|>", 44: "<|channel|>final<|message|>The answer is 4.",
        45: "<|start|>assistant<|channel|>final<|message|>unexpected text after the call",
        50: " is STOP here",
    ]
    /// Special-token spellings the tokenizer converts back to ids.
    static let special: [String: Int] = [
        "<|endoftext|>": 10, "<|im_end|>": 11, "<end_of_turn>": 12, "<eos>": 13,
        "<|call|>": 41, "<|return|>": 42,
    ]
}

struct ParityTokenizer: MLXLMCommon.Tokenizer {
    let eos: String
    /// GPT-OSS spells `<|endoftext|>` with its own id.
    let harmony: Bool
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { ParityPieces.table[$0] ?? "" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        if harmony, token == "<|endoftext|>" { return 43 }
        return ParityPieces.special[token]
    }
    func convertIdToToken(_ id: Int) -> String? { ParityPieces.table[id] }
    var bosToken: String? { nil }
    var eosToken: String? { eos }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2, 3] }
}

// MARK: - Model families

/// One family's artifact files (only the fields both servers read) and the
/// token scripts its answers use.
struct ParityFamily: Sendable {
    let name: String
    let modelType: String
    let modelID: String
    let configJSON: String
    let generationJSON: String?
    let eosToken: String
    let harmony: Bool
    let plain: [Int]
    let tool: [Int]
    let stopString: [Int]
    let long: [Int]
    let json: [Int]

    /// Shapes of the real artifacts' EOS fields (config.json top level,
    /// text_config, generation_config.json), on the fixture vocabulary.
    static let all: [ParityFamily] = [
        // Qwen 3.8 27B / Qwen 3.5-3.6 A3B: top [eot, im_end], text_config eot, generation [eot, im_end].
        .init(name: "qwen3.8-27b", modelType: "qwen3_5", modelID: "qwen3.8-27b-parity",
              configJSON: #"{"model_type":"qwen3_5","eos_token_id":[10,11],"text_config":{"eos_token_id":10,"vocab_size":512}}"#,
              generationJSON: #"{"eos_token_id":[10,11]}"#, eosToken: "<|im_end|>", harmony: false,
              plain: [20, 21, 22, 11], tool: [20, 21, 30, 11], stopString: [21, 22, 50, 23, 11],
              long: [21, 22, 23, 24, 25, 26, 11], json: [21, 27, 11]),
        // Qwen 3.5 9B: text_config eot only, no generation config.
        .init(name: "qwen3.5-9b", modelType: "qwen3_5", modelID: "qwen3.5-9b-parity",
              configJSON: #"{"model_type":"qwen3_5","text_config":{"eos_token_id":10,"vocab_size":512}}"#,
              generationJSON: nil, eosToken: "<|im_end|>", harmony: false,
              plain: [21, 22, 10, 23, 11], tool: [21, 30, 11], stopString: [21, 22, 50, 23, 11],
              long: [21, 22, 23, 24, 25, 26, 11], json: [21, 27, 11]),
        .init(name: "qwen3.5-35b-a3b", modelType: "qwen3_5_moe", modelID: "qwen3.5-35b-a3b-parity",
              configJSON: #"{"model_type":"qwen3_5_moe","eos_token_id":[10,11],"text_config":{"eos_token_id":10,"vocab_size":512}}"#,
              generationJSON: #"{"eos_token_id":[10,11]}"#, eosToken: "<|im_end|>", harmony: false,
              plain: [20, 21, 22, 11], tool: [20, 21, 30, 11], stopString: [21, 22, 50, 23, 11],
              long: [21, 22, 23, 24, 25, 26, 11], json: [21, 27, 11]),
        // Bonsai: text_config eot, generation im_end only.
        .init(name: "bonsai-27b", modelType: "prism_hadamard_qwen35", modelID: "ternary-bonsai-2-27b-parity",
              configJSON: #"{"model_type":"prism_hadamard_qwen35","text_config":{"eos_token_id":10,"vocab_size":512}}"#,
              generationJSON: #"{"eos_token_id":11}"#, eosToken: "<|im_end|>", harmony: false,
              plain: [21, 22, 10, 23, 11], tool: [21, 30, 11], stopString: [21, 22, 50, 23, 11],
              long: [21, 22, 23, 24, 25, 26, 11], json: [21, 27, 11]),
        // GPT-OSS: config <|return|>, generation [<|endoftext|>, <|return|>, <|call|>].
        .init(name: "gpt-oss-20b", modelType: "gpt_oss", modelID: "gpt-oss-20b-parity",
              configJSON: #"{"model_type":"gpt_oss","eos_token_id":42,"vocab_size":512}"#,
              generationJSON: #"{"eos_token_id":[43,42,41]}"#, eosToken: "<|return|>", harmony: true,
              plain: [44, 42], tool: [40, 41, 45, 42], stopString: [44, 50, 23, 42],
              long: [44, 23, 24, 25, 26, 42], json: [27, 42]),
        // Nemotron 3.5: config and generation [2-like, 11]; sampling defaults from generation_config.
        .init(name: "nemotron-3.5", modelType: "nemotron_h", modelID: EngineV2SupportedModels.nemotron35LightningModelID,
              configJSON: #"{"model_type":"nemotron_h","eos_token_id":[13,11],"vocab_size":512}"#,
              generationJSON: #"{"eos_token_id":[13,11],"do_sample":true,"temperature":0.6,"top_p":0.95}"#,
              eosToken: "<|im_end|>", harmony: false,
              plain: [21, 22, 11], tool: [21, 31, 11], stopString: [21, 22, 50, 23, 11],
              long: [21, 22, 23, 24, 25, 26, 11], json: [21, 27, 11]),
        .init(name: "gemma-4", modelType: "gemma4", modelID: "gemma-4-26b-parity",
              configJSON: #"{"model_type":"gemma4","text_config":{"eos_token_id":[13,12],"vocab_size":512}}"#,
              generationJSON: #"{"eos_token_id":[13,12]}"#, eosToken: "<end_of_turn>", harmony: false,
              plain: [22, 12], tool: [32, 12], stopString: [22, 50, 23, 12],
              long: [22, 23, 24, 25, 26, 12], json: [27, 12]),
    ]

    var tokenizer: ParityTokenizer { .init(eos: eosToken, harmony: harmony) }

    /// A fresh artifact directory with this family's configuration files.
    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("api-parity-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(configJSON.utf8).write(to: directory.appendingPathComponent("config.json"))
        if let generationJSON {
            try Data(generationJSON.utf8).write(to: directory.appendingPathComponent("generation_config.json"))
        }
        return directory
    }

    /// The EOS ids the model loader gives a single-Mac slot
    /// (`LLMModelFactory` / `VLMModelFactory`): config.json's top-level
    /// `eos_token_id`, replaced by generation_config.json's when present.
    func loaderEOS(_ directory: URL) throws -> Set<Int> {
        let base = try JSONDecoder.json5().decode(
            BaseConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        var ids = Set(base.eosTokenIds?.values ?? [])
        if let data = try? Data(contentsOf: directory.appendingPathComponent("generation_config.json")),
           let generation = try? JSONDecoder.json5().decode(GenerationConfigFile.self, from: data),
           let values = generation.eosTokenIds?.values {
            ids = Set(values)
        }
        return ids
    }

    /// What the installed cluster model records (`DistributedInstalledModel.make`):
    /// text_config's EOS, else the top level's.
    func installedEOS() throws -> Set<Int> {
        let object = try #require(JSONSerialization.jsonObject(with: Data(configJSON.utf8)) as? [String: Any])
        let text = object["text_config"] as? [String: Any]
        let raw = text?["eos_token_id"] ?? object["eos_token_id"]
        if let value = raw as? Int { return [value] }
        return Set(try #require(raw as? [Int]))
    }
}

// MARK: - Engines that commit the script

/// The script both fake engines commit for the next request, and how it ends.
final class ParityScript: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int] = []
    private var failure = false
    func set(_ value: [Int], failure: Bool = false) { lock.withLock { tokens = value; self.failure = failure } }
    var current: (tokens: [Int], failure: Bool) { lock.withLock { (tokens, failure) } }
}

/// Single-Mac fake engine: commits the script with the product engine's
/// rules (a stop token counts and renders nothing; a stop string or stop
/// token ends with `stop`; `max_tokens` ends with `length`).
final class ParityScriptedEngine: CBv2Engine, @unchecked Sendable {
    let script: ParityScript
    let detokenizers: CBv2TextDetokenizerFactory
    private let lock = NSLock()
    private var received: [CBv2Request] = []
    init(script: ParityScript, tokenizer: any MLXLMCommon.Tokenizer) {
        self.script = script; detokenizers = CBv2TextDetokenizerFactory(tokenizer: tokenizer)
    }
    var requests: [CBv2Request] { lock.withLock { received } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { received.append(request) }
        let (tokens, failure) = script.current
        let detokenizer = detokenizers.makeDetokenizer(stopStrings: request.stopStrings)
        return AsyncStream { continuation in
            var count = 0
            var reason: CBv2FinishReason?
            for token in tokens {
                guard count < request.maxTokens else { break }
                count += 1
                let isStop = request.stopTokens.contains(token)
                let text = isStop ? "" : detokenizer.push([token])
                continuation.yield(.delta(text: text, tokens: [token], logprobs: nil))
                if isStop || detokenizer.matchedStopString { reason = .stop; break }
                if count == request.maxTokens { reason = .length; break }
            }
            let usage = CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: count)
            if failure {
                continuation.yield(.finished(reason: .error("fixture failure"), usage: usage))
            } else {
                var finish = reason ?? .stop
                let tail = detokenizer.flush()
                if !tail.isEmpty { continuation.yield(.delta(text: tail, tokens: [], logprobs: nil)) }
                if detokenizer.matchedStopString { finish = .stop }
                continuation.yield(.finished(reason: finish, usage: usage))
            }
            continuation.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// Cluster session over the fabricated owner, for one family's artifact.
final class ParityClusterSession: DistributedLocalServerSession, @unchecked Sendable {
    let base = DistributedTestOwner()
    let profile: DistributedResidentExecutionProfile
    let model: DistributedInstalledModel
    private let lock = NSLock()
    private var phase: DistributedInstalledSessionStatus = .prepared

    init(family: ParityFamily, directory: URL) throws {
        profile = try .init(id: "fabricated-greedy", vocabularySize: 512, maxPromptTokens: 8192,
                            maxOutputTokens: 4096, maxContextTokens: 8192 + 4096, requestTimeout: .seconds(315))
        model = .init(publicModelID: family.modelID, directory: directory, modelType: family.modelType,
                      eosTokenIDs: try family.installedEOS(), vocabularySize: 512)
        base.capacityBytes = 1 << 20
    }
    var expectedIdentity: DistributedResidentIdentity { base.identity }
    var status: DistributedInstalledSessionStatus { lock.withLock { phase } }
    var httpAdmissionAvailable: Bool { lock.withLock { phase == .ready } }
    var httpSessionInvalid: Bool { false }
    func validateModelInputs() throws {}
    func start() async throws { lock.withLock { phase = .ready } }
    func stop(until deadline: UInt64) async -> DistributedInstalledSessionStatus {
        lock.withLock { if phase != .released { phase = .stopping } }
        return status
    }
    func drain(until deadline: UInt64) async -> DistributedInstalledSessionStatus { status }
    func shutdown() async { lock.withLock { phase = .released } }
    func readiness() -> DistributedResidentReadiness? { status == .ready ? base.readiness() : nil }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        base.setReadinessInvalidationHandler(handler)
    }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        base.projectFirstToken(request, admission: admission)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        try base.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int,
                 deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        try reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
}

// MARK: - The two servers

final class ParityPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16?
    func set(_ port: UInt16) { lock.withLock { value = port } }
    var port: UInt16? { lock.withLock { value } }
}

let parityToken = "parity-token"

/// The single-Mac local endpoint for one family, as `StandaloneServer` builds it.
struct ParitySoloServer {
    let engine: ParityScriptedEngine
    let bridge: EngineV2Bridge
    let task: Task<Void, Never>
    let port: UInt16

    static func start(family: ParityFamily, directory: URL, script: ParityScript) async throws -> Self {
        let tokenizer = family.tokenizer
        // `ProviderModelContainer.tokenizerHandle`: the Gemma contract check.
        let handle = TokenizerHandle(tokenizer, toolConstraintContractVerified:
            Gemma4ToolConstraintContract.isVerified(modelType: family.modelType, modelDirectory: directory))
        let engine = ParityScriptedEngine(script: script, tokenizer: tokenizer)
        // `EngineV2SlotFactory`: loader EOS + model EOS policy, artifact sampling defaults.
        let eos = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: family.modelID, modelType: family.modelType, base: try family.loaderEOS(directory),
            tokenToId: { tokenizer.convertTokenToId($0) })
        let bridge = EngineV2Bridge(
            engine: engine, modelId: family.modelID, tokenizer: handle, eosTokenIds: eos,
            samplingDefaults: EngineV2SamplingDefaults.resolve(
                modelId: family.modelID, modelType: family.modelType, modelDirectory: directory),
            defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens)
        let modelID = family.modelID, modelType = family.modelType
        let box = ParityPortBox()
        let application = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: parityToken),
            defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens,
            acquire: { id in
                guard id == modelID else { throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) }
                return .init(tokenizer: handle, releaseToken: OneShotRelease(release: { _ in }, modelId: id),
                             modelType: modelType, container: nil, isVLM: false, engineV2Bridge: bridge,
                             visionGate: VisionMemoryGate(kvBudget: nil, fp16KVBytesPerToken: 0, contextLength: 0))
            },
            tokenizerProvider: { id in
                if let id, id != modelID { throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) }
                return .init(tokenizer: handle, modelType: modelType)
            },
            availableModels: { [modelID] }, mtpSlots: { [] },
            responseTracker: LocalResponseTracker(),
            onServerRunning: { channel in
                if let port = channel.localAddress?.port, let value = UInt16(exactly: port) { box.set(value) }
            },
            modelTypeProvider: { id in id == modelID ? modelType : nil })
        let task = Task<Void, Never> {
            do { try await application.runService(gracefulShutdownSignals: []) } catch {}
        }
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while box.port == nil, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        return .init(engine: engine, bridge: bridge, task: task, port: try #require(box.port))
    }

    func stop() async {
        task.cancel()
        await bridge.shutdown()
    }
}

/// The cluster's local endpoint for one family.
struct ParityClusterServer {
    let session: ParityClusterSession
    let host: DistributedLocalServer
    let port: UInt16

    static func start(family: ParityFamily, directory: URL) async throws -> Self {
        let session = try ParityClusterSession(family: family, directory: directory)
        let tokenizer = family.tokenizer
        // As `StartCommand+Distributed`: the plan's first-token budget is bound.
        let host = DistributedLocalServer(session: session,
            config: .init(host: "127.0.0.1", port: 0, authToken: parityToken),
            firstTokenBudgetPolicy: try .init(baseMilliseconds: 60_000, millisecondsPerInputToken: 0),
            tokenizerLoader: { _ in TokenizerHandle(tokenizer) })
        try await host.start()
        return .init(session: session, host: host, port: try #require(await host.status.boundPort))
    }

    /// Commits the script on the request's lease as the worker pair would,
    /// then acknowledges retirement. Returns without acting when no request
    /// reaches the pair (a refusal before admission).
    func drive(after reservations: Int, script: [Int], failure: Bool, stop: ParityStopFlag) async {
        let owner = session.base
        while owner.reserveCount == reservations {
            if stop.isSet { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let lease = owner.lease(reservations)
        while lease.startCount == 0 {
            if stop.isSet { lease.acknowledge(); return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        for token in script {
            if !lease.send(.token(token)) { break }
        }
        if failure { lease.send(.finished(.error("fixture failure"))) }
        lease.acknowledge()
    }

    func stop() async { _ = await host.stop(until: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) }
}

final class ParityStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// MARK: - Requests and normalized answers

enum ParityScriptKind: Sendable {
    case plain, tool, stopString, long, json, none

    func tokens(_ family: ParityFamily) -> [Int] {
        switch self {
        case .plain: family.plain
        case .tool: family.tool
        case .stopString: family.stopString
        case .long: family.long
        case .json: family.json
        case .none: []
        }
    }
}

struct ParityCase: Sendable {
    let name: String
    let method: String
    let path: String
    /// JSON body text; nil for GET.
    let body: String?
    let authorized: Bool
    /// Which script the engine commits.
    let script: ParityScriptKind
    let failure: Bool

    init(_ name: String, method: String = "POST", path: String = "/v1/chat/completions", body: String?,
         authorized: Bool = true, script: ParityScriptKind = .plain, failure: Bool = false) {
        self.name = name; self.method = method; self.path = path; self.body = body
        self.authorized = authorized; self.script = script; self.failure = failure
    }

    static let weatherTool = #"{"type":"function","function":{"name":"get_weather","description":"Weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}"#

    static func chat(_ model: String, _ extra: String = "", stream: Bool = false) -> String {
        let usage = stream ? #","stream_options":{"include_usage":true}"# : ""
        return #"{"model":"\#(model)","messages":[{"role":"user","content":"fixture"}],"stream":\#(stream)\#(usage)\#(extra)}"#
    }

    static func all(_ family: ParityFamily) -> [ParityCase] {
        let m = family.modelID
        let tools = #","tools":[\#(weatherTool)]"#
        return [
            .init("plain", body: chat(m)),
            .init("plain-stream", body: chat(m, stream: true)),
            .init("max-completion-tokens", body: chat(m, #","max_completion_tokens":3"#), script: .long),
            .init("max-tokens-stream", body: chat(m, #","max_tokens":2"#, stream: true), script: .long),
            .init("stop-string", body: chat(m, #","stop":["STOP"]"#), script: .stopString),
            .init("stop-string-stream", body: chat(m, #","stop":"STOP""#, stream: true), script: .stopString),
            .init("tools", body: chat(m, tools), script: .tool),
            .init("tools-stream", body: chat(m, tools, stream: true), script: .tool),
            .init("tool-choice-auto-plain", body: chat(m, tools + #","tool_choice":"auto""#)),
            .init("tool-choice-required", body: chat(m, tools + #","tool_choice":"required""#), script: .tool),
            .init("tool-choice-named-stream", body: chat(m,
                tools + #","tool_choice":{"type":"function","function":{"name":"get_weather"}}"#, stream: true),
                script: .tool),
            .init("tool-choice-none", body: chat(m, tools + #","tool_choice":"none""#)),
            .init("parallel-tool-calls-false", body: chat(m, tools + #","parallel_tool_calls":false"#), script: .tool),
            .init("tool-history", body: #"{"model":"\#(m)","messages":[{"role":"user","content":"fixture"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"sunny"}]\#(tools)}"#),
            .init("sampling", body: chat(m, #","temperature":0.7,"top_p":0.9,"top_k":20,"min_p":0.05,"seed":7,"frequency_penalty":0.3,"presence_penalty":0.2,"repetition_penalty":1.1"#)),
            .init("logit-bias", body: chat(m, #","logit_bias":{"22":-5,"23":2}"#)),
            .init("json-mode", body: chat(m, #","response_format":{"type":"json_object"}"#), script: .json),
            .init("json-schema", body: chat(m, #","response_format":{"type":"json_schema","json_schema":{"name":"a","schema":{"type":"object","properties":{"answer":{"type":"integer"}}}}}"#), script: .json),
            .init("thinking-off", body: chat(m, #","chat_template_kwargs":{"enable_thinking":false}"#)),
            .init("reasoning-parser", body: chat(m, #","reasoning_parser":"think""#, stream: true)),
            .init("logprobs", body: chat(m, #","logprobs":true,"top_logprobs":2"#)),
            .init("n-two", body: chat(m, #","n":2"#)),
            .init("engine-failure-stream", body: chat(m, stream: true), failure: true),
            .init("engine-failure", body: chat(m), failure: true),
            .init("completions", path: "/v1/completions", body: #"{"model":"\#(m)","prompt":"fixture"}"#),
            .init("completions-stream", path: "/v1/completions", body: #"{"model":"\#(m)","prompt":"fixture","stream":true}"#),
            .init("responses", path: "/v1/responses", body: #"{"model":"\#(m)","input":"fixture"}"#),
            .init("responses-stream", path: "/v1/responses", body: #"{"model":"\#(m)","input":"fixture","stream":true}"#),
            .init("image-input", body: #"{"model":"\#(m)","messages":[{"role":"user","content":[{"type":"text","text":"what is this"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}]}]}"#, script: .none),
            .init("unknown-model", body: chat("not-served-model"), script: .none),
            .init("malformed-body", body: #"{"model":"\#(m)","messages":"#, script: .none),
            .init("no-auth", body: chat(m), authorized: false, script: .none),
            .init("models", method: "GET", path: "/v1/models", body: nil, script: .none),
            .init("tokenize", path: "/tokenize", body: #"{"model":"\#(m)","prompt":"fixture"}"#, script: .none),
        ]
    }
}

/// An answer reduced to what a client can observe, minus ids and timestamps.
struct ParityAnswer: Equatable, CustomStringConvertible {
    let status: Int
    let contentType: String?
    let cacheControl: String?
    /// JSON (keys sorted) or, for an event stream, its `data:` frames in
    /// order with SSE comments removed.
    let body: [String]

    var description: String {
        "status=\(status) content-type=\(contentType ?? "-") cache-control=\(cacheControl ?? "-")\n  "
            + body.joined(separator: "\n  ")
    }

    static let volatileKeys: Set<String> = ["id", "created", "created_at", "system_fingerprint", "response_id",
                                            "item_id", "call_id"]

    static func normalized(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in object where !volatileKeys.contains(key) { result[key] = normalized(item) }
            return result
        }
        if let array = value as? [Any] { return array.map(normalized) }
        return value
    }

    static func canonical(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let bytes = try? JSONSerialization.data(withJSONObject: normalized(object),
                                                      options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    init(status: Int, contentType: String?, cacheControl: String?, data: Data) {
        self.status = status; self.contentType = contentType; self.cacheControl = cacheControl
        let text = String(decoding: data, as: UTF8.self)
        if contentType?.hasPrefix("text/event-stream") == true {
            var frames: [String] = []
            for block in text.components(separatedBy: "\n\n") where !block.isEmpty {
                // SSE comments (`:` lines) are not events; clients skip them.
                let lines = block.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix(":") }
                guard !lines.isEmpty else { continue }
                frames.append(lines.map { line in
                    line.hasPrefix("data: ") ? "data: " + Self.canonical(String(line.dropFirst(6))) : String(line)
                }.joined(separator: "\n"))
            }
            body = frames
        } else {
            body = text.isEmpty ? [] : [Self.canonical(text)]
        }
    }
}

func paritySend(port: UInt16, _ testCase: ParityCase, session: URLSession) async throws -> ParityAnswer {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(testCase.path)")!)
    request.httpMethod = testCase.method
    request.timeoutInterval = 20
    if testCase.authorized { request.setValue("Bearer \(parityToken)", forHTTPHeaderField: "Authorization") }
    if let body = testCase.body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
    }
    let (data, reply) = try await session.data(for: request)
    let http = try #require(reply as? HTTPURLResponse)
    return ParityAnswer(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                        cacheControl: http.value(forHTTPHeaderField: "Cache-Control"), data: data)
}

/// The request as it reached each engine: what the model is asked to do.
struct ParityEngineRequest: Equatable, CustomStringConvertible {
    let promptTokens: [Int]
    let maxTokens: Int
    let stopTokens: [Int]
    let stopStrings: [String]
    let temperature: Float, topP: Float, topK: Int, minP: Float
    let repetitionPenalty: Float, frequencyPenalty: Float, presencePenalty: Float
    let logitBias: [Int: Float]
    let topLogprobs: Int
    /// Only a seed the client chose; an omitted one is each engine's own fallback.
    let seed: UInt64?
    let constrained: Bool

    init(_ request: CBv2Request, clientSeed: Bool) {
        promptTokens = request.promptTokens; maxTokens = request.maxTokens
        stopTokens = request.stopTokens.sorted(); stopStrings = request.stopStrings
        let p = request.sampling
        temperature = p.temperature; topP = p.topP; topK = p.topK; minP = p.minP
        repetitionPenalty = p.repetitionPenalty; frequencyPenalty = p.frequencyPenalty
        presencePenalty = p.presencePenalty; logitBias = p.logitBias; topLogprobs = p.topLogprobs
        seed = clientSeed ? p.seed : nil
        constrained = request.tokenConstraint != nil
    }

    var description: String {
        "prompt=\(promptTokens) max=\(maxTokens) stopTokens=\(stopTokens) stopStrings=\(stopStrings) "
            + "T=\(temperature) topP=\(topP) topK=\(topK) minP=\(minP) rep=\(repetitionPenalty) "
            + "freq=\(frequencyPenalty) pres=\(presencePenalty) bias=\(logitBias.sorted { $0.key < $1.key }) "
            + "topLogprobs=\(topLogprobs) seed=\(seed.map(String.init) ?? "-") constrained=\(constrained)"
    }
}

/// One family through every case on both servers. Returns the mismatches.
func parityRun(_ family: ParityFamily) async throws -> [String] {
    let directory = try family.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = ParityScript()
    let solo = try await ParitySoloServer.start(family: family, directory: directory, script: script)
    let cluster = try await ParityClusterServer.start(family: family, directory: directory)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 4
    let client = URLSession(configuration: configuration)
    var mismatches: [String] = []
    do {
        for testCase in ParityCase.all(family) {
            // A failure ends the answer after its first committed token.
            let planned = testCase.script.tokens(family)
            let tokens = testCase.failure ? Array(planned.prefix(1)) : planned
            script.set(tokens, failure: testCase.failure)
            let soloBefore = solo.engine.requests.count
            let soloAnswer = try await paritySend(port: solo.port, testCase, session: client)

            let reservations = cluster.session.base.reserveCount
            let stop = ParityStopFlag()
            let driver = Task { await cluster.drive(after: reservations, script: tokens, failure: testCase.failure, stop: stop) }
            let clusterAnswer: ParityAnswer
            do { clusterAnswer = try await paritySend(port: cluster.port, testCase, session: client) }
            catch { stop.set(); await driver.value; throw error }
            stop.set(); await driver.value

            if soloAnswer != clusterAnswer {
                mismatches.append("[\(family.name)] \(testCase.name): HTTP answers differ\n single-Mac: \(soloAnswer)\n cluster:    \(clusterAnswer)")
            }
            let clientSeed = testCase.body?.contains("\"seed\"") == true
            let soloRequest = solo.engine.requests.count > soloBefore
                ? solo.engine.requests.last.map { ParityEngineRequest($0, clientSeed: clientSeed) } : nil
            let clusterRequest = cluster.session.base.reserveCount > reservations
                ? cluster.session.base.reservedRequests.last.map { ParityEngineRequest($0, clientSeed: clientSeed) } : nil
            if soloRequest != clusterRequest {
                mismatches.append("[\(family.name)] \(testCase.name): engine requests differ\n single-Mac: \(soloRequest.map(String.init(describing:)) ?? "none")\n cluster:    \(clusterRequest.map(String.init(describing:)) ?? "none")")
            }
            // The cluster serves one request at a time: the next one starts
            // once this one retired (the engine published its terminal).
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < end {
                let held = await !cluster.host.pins.isEmpty
                let queued = await !cluster.host.waiting.isEmpty
                if !held && !queued { break }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    } catch {
        client.invalidateAndCancel()
        await cluster.stop(); await solo.stop()
        throw error
    }
    client.invalidateAndCancel()
    await cluster.stop(); await solo.stop()
    return mismatches
}

/// Evidence for the report: the mismatches, when a path is given.
func parityRecord(_ lines: [String], family: String) {
    guard let folder = ProcessInfo.processInfo.environment["DARKBLOOM_API_PARITY_REPORT_DIR"] else { return }
    let url = URL(fileURLWithPath: folder).appendingPathComponent("parity-\(family).txt")
    let text = lines.isEmpty ? "PARITY: every case identical\n" : lines.joined(separator: "\n\n") + "\n"
    try? Data(text.utf8).write(to: url)
}
