import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Private, synthetic-only diagnostic. Observes the unchanged production
/// engine event stream before channel/tool output parsing, retaining normal
/// provider loading, prompt preparation, submission, admission and sampling.
@Suite("Flash-Next opaque raw generation diagnostic", .serialized)
struct FlashNextOpaqueRawDiagnosticTests {
    @Test(.enabled(if:
        ProcessInfo.processInfo.environment["DARKBLOOM_FLASH_NEXT_RAW_DIAGNOSTIC"] == "1"
            && ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1"))
    func captureUnparsedSyntheticOpaqueRequests() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["DARKBLOOM_CBV2_MTP"] == "0")
        try #require(env["DARKBLOOM_PREFIX_CACHE"] == "0")
        try #require(env["DARKBLOOM_PREFIX_CACHE_MEMORY"] == "0")
        let artifact = URL(fileURLWithPath: try #require(env["DARKBLOOM_QWEN4_REAL_MODEL"]))
        let requests = URL(fileURLWithPath: try #require(env["DARKBLOOM_RAW_OPAQUE_REQUEST_DIR"]))
        let output = URL(fileURLWithPath: try #require(env["DARKBLOOM_RAW_OPAQUE_OUTPUT_DIR"]))
        for path in [artifact.path, requests.path, output.path] { try #require(path.hasPrefix("/")) }
        let artifactConfigHash = try hash(Data(contentsOf: artifact.appendingPathComponent("config.json")))
        try #require(["8c74c1ecf70cc39fdb41c2e35e02e585bb91b389b0dc4e9768786f51babe94cf",
                      "f04c5e8f500fe880617bf10a4ac6efc063b6ef8dbe66fb6a4843407c18ce7dae"].contains(artifactConfigHash))
        try #require(hash(Data(contentsOf: artifact.appendingPathComponent("model.safetensors.index.json")))
            == "7fccee8cf9d3b2a7af16e34dec85ccd3558bb3aa7a399ab9eee2b3211cd8fbde")
        let modelID = Qwen4SupportPolicy.ownedModelID
        let resolved = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        let actualConfig = try Data(contentsOf: resolved.appendingPathComponent("config.json"))
        try #require(hash(actualConfig) == artifactConfigHash)
        let index = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: artifact.appendingPathComponent("model.safetensors.index.json"))) as? [String: Any])
        let weights = try #require(index["weight_map"] as? [String: String])
        try #require(weights.count == 3866 && Set(weights.values).count == 131)
        for name in Set(weights.values) {
            try #require(!name.contains("/") && name != "..")
            let actual = try FileManager.default.attributesOfItem(
                atPath: resolved.appendingPathComponent(name).resolvingSymlinksInPath().path)
            let expected = try FileManager.default.attributesOfItem(
                atPath: artifact.appendingPathComponent(name).resolvingSymlinksInPath().path)
            try #require(actual[.systemNumber] as? NSNumber == expected[.systemNumber] as? NSNumber)
            try #require(actual[.systemFileNumber] as? NSNumber == expected[.systemFileNumber] as? NSNumber)
        }
        // Small metadata may be copied instead of linked. Its content, not
        // its filesystem identity, is the serving contract.
        for name in ["config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"] {
            let actualHash = hash(try Data(contentsOf: resolved.appendingPathComponent(name)))
            let expectedHash = hash(try Data(contentsOf: artifact.appendingPathComponent(name)))
            try #require(actualHash == expectedHash)
        }
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: artifact, modelName: modelID))
        let hardware = try HardwareDetector.detect()
        let loop = try ProviderLoop(config: .init(
            coordinatorURL: "ws://127.0.0.1:1/unused", hardware: hardware, models: [model],
            config: .init(provider: .init(name: "opaque-raw-synthetic-diagnostic"),
                backend: .init(idleTimeoutMins: 0, maxModelSlots: 1, mtpMode: .auto))),
            purgeLegacyFiles: false, attestationSigner: nil)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        // Refuse to overwrite any earlier receipt directory.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        await loop.setDaemonStateFileForTesting(output.appendingPathComponent("daemon-state.json"))
        do {
            try await loop.ensureModelLoaded(modelId: modelID, allowEviction: false)
            let bridge = try #require(await loop.slotBridgeForTesting(modelId: modelID))
            try #require(await bridge.kvBackendKind == .paged)
            try #require(await bridge.mtpStatusSnapshot().active == false)
            let recorder = OpaqueRawEventRecorder()
            try await bridge.installOpaqueRawRecorder(recorder)
            let tokenizer = await bridge.tokenizer
            let stops = await bridge.stopTokenIds
            var cases = [false, true].map { (thinking: $0, name: "opaque-chat-thinking-\($0)-stream-false", directory: requests) }
            if let variants = env["DARKBLOOM_RAW_TAG_VARIANT_DIR"] {
                try #require(variants.hasPrefix("/"))
                cases += [false, true].map {
                    (thinking: $0, name: "literal-control-tags-thinking-\($0)", directory: URL(fileURLWithPath: variants))
                }
            }
            for testCase in cases {
                let (thinking, name, directory) = testCase
                let receipt = try #require(JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent(name + ".json"))) as? [String: Any])
                let object = try #require(receipt["request"] as? [String: Any])
                let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                let request = try ProviderLoop.decodeOpenAIRequest(body)
                try #require(request.model == modelID && request.temperature == 0)
                try #require(request.maxTokens == 768 && request.seed == 424242)
                try #require(request.parallelToolCalls == false && request.toolChoice == .mode(.required))
                try #require(request.tools?.map(\.function.name) == ["record_text"])
                try #require(request.messages.count == 1 && request.messages[0].textContent.hasPrefix(
                    "Call record_text exactly once. Copy the value of text from this JSON object exactly,"))
                try #require(request.reasoning?.enabled == thinking)
                let prepared = try ToolChoicePromptPolicy.prepare(request)
                let controls = ProviderLoop.extractChatTemplateControls(from: body).resolvingPromptDate()
                let tokens = try ProviderPromptContractPipeline.tokenize(
                    prepared: prepared, request: request, tokenizer: tokenizer.inner,
                    modelType: model.modelType, templateControls: controls)
                let translated = MultiModelBatchSchedulerEngine.translate(
                    openAIRequest: request, defaultMaxTokens: 768)
                recorder.reset()
                var bridgeText = ""
                let events = await bridge.submitTokenized(
                    promptTokens: tokens, request: translated,
                    requestId: "opaque-raw-\(thinking)", cacheEnabled: false)
                for await event in events {
                    switch event {
                    case .chunk(let text): bridgeText += text
                    case .error(let error): throw OpaqueRawFailure(message: error)
                    default: break
                    }
                }
                let trace = recorder.snapshot()
                let specialNames = ["<think>", "</think>", "<tool_call>", "</tool_call>",
                                    "<|im_end|>", "<|endoftext|>"]
                let specials = Dictionary(uniqueKeysWithValues: specialNames.map {
                    ($0, tokenizer.inner.convertTokenToId($0) as Any? ?? NSNull())
                })
                let result: [String: Any] = [
                    "synthetic_only": true, "mtp": false, "thinking": thinking,
                    "artifact_config_sha256": artifactConfigHash,
                    "request": object, "request_canonical_sha256": hash(body),
                    "prompt_token_ids": tokens,
                    "prompt_decoded_with_specials": tokenizer.inner.decode(tokenIds: tokens, skipSpecialTokens: false),
                    "raw_token_ids": trace.tokens,
                    "raw_decoded_with_specials": tokenizer.inner.decode(tokenIds: trace.tokens, skipSpecialTokens: false),
                    "raw_engine_text": trace.text, "raw_bridge_text": bridgeText,
                    "token_pieces": trace.tokens.enumerated().map { index, token -> [String: Any] in
                        ["index": index, "id": token,
                         "vocabulary_piece": tokenizer.inner.convertIdToToken(token) as Any? ?? NSNull(),
                         "decoded_alone": tokenizer.inner.decode(tokenIds: [token], skipSpecialTokens: false),
                         "is_stop": stops.contains(token)]
                    },
                    "special_token_ids": specials, "stop_token_ids": stops.sorted(),
                    "terminal": trace.finish ?? "missing", "completion_tokens": trace.completionTokens,
                    "capture_overflow": trace.overflow,
                    "scope": "Normal production engine/admission/prompt; downstream channel/tool parsing bypassed only for private synthetic diagnosis. Not a passing API test.",
                ]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent(name + "-raw.json"), options: .atomic)
                try #require(!trace.overflow && !trace.tokens.isEmpty && trace.finish != nil)
                print("opaque-raw thinking=\(thinking) prompt=\(tokens.count) completion=\(trace.completionTokens) terminal=\(trace.finish!)")
            }
            try #require(await loop.unloadModel(modelID))
        } catch {
            _ = await loop.unloadModel(modelID)
            throw error
        }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct OpaqueRawFailure: Error { let message: String }

private final class OpaqueRawEventRecorder: @unchecked Sendable {
    struct Snapshot { var tokens: [Int] = []; var text = ""; var finish: String?; var completionTokens = 0; var overflow = false }
    private let lock = NSLock()
    private var state = Snapshot()
    func reset() { lock.withLock { state = Snapshot() } }
    func snapshot() -> Snapshot { lock.withLock { state } }
    func record(_ event: CBv2Event) {
        lock.withLock {
            switch event {
            case .delta(let text, let tokens, _):
                guard state.tokens.count + tokens.count <= 1024, state.text.utf8.count + text.utf8.count <= 131072 else {
                    state.overflow = true; return
                }
                state.tokens += tokens; state.text += text
            case .finished(let reason, let usage):
                state.finish = String(describing: reason); state.completionTokens = usage.completionTokens
            }
        }
    }
}

private extension EngineV2Bridge {
    func installOpaqueRawRecorder(_ recorder: OpaqueRawEventRecorder) throws {
        let base = try #require(ownedEngine)
        try #require(base is EngineV2)
        try #require(ssdPrefixCache == nil && ssdHybridCheckpointStore == nil && residentPrefixCacheEvidence == nil)
        try #require(firstTokenDeadlineAdmission(deadline: nil, isMultimodal: false) == nil)
        // Initialization has already completed with the real EngineV2. The
        // later concrete casts are checkpoint staging (disabled here) and
        // read-only MTP telemetry (inactive here), not model execution.
        ownedEngine = OpaqueRawRecordingEngine(base: base, recorder: recorder)
    }
}

/// A transparent test-only observation wrapper: no sampler/model/control edits.
private final class OpaqueRawRecordingEngine: CBv2Engine, @unchecked Sendable {
    let base: any CBv2Engine
    let recorder: OpaqueRawEventRecorder
    init(base: any CBv2Engine, recorder: OpaqueRawEventRecorder) { self.base = base; self.recorder = recorder }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        observe(try base.submit(request))
    }
    private func observe(_ input: AsyncStream<CBv2Event>) -> AsyncStream<CBv2Event> {
        return AsyncStream { continuation in
            let task = Task { [recorder] in
                for await event in input { recorder.record(event); continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func submit(_ request: CBv2Request, firstTokenDeadline: CBv2FirstTokenDeadlineAdmission) async throws -> CBv2FirstTokenDeadlineResult {
        switch try await base.submit(request, firstTokenDeadline: firstTokenDeadline) {
        case .admitted(let stream, let projectedWork, let admittedAt, let retirement):
            return .admitted(stream: observe(stream), projectedWork: projectedWork,
                admittedAt: admittedAt, retirement: retirement)
        case .deadlineUnreachable(let projectedWork):
            return .deadlineUnreachable(projectedWork: projectedWork)
        }
    }
    func cancel(_ id: CBv2RequestID) { base.cancel(id) }
    func capacity() -> CBv2CapacitySnapshot { base.capacity() }
    func residentPrefixCandidate(for request: CBv2Request) -> CBv2ResidentPrefixCandidate? { base.residentPrefixCandidate(for: request) }
    func packedPrefillActivity() -> CBv2PackedPrefillActivity { base.packedPrefillActivity() }
    func updateKVBytesCapacity(_ bytes: Int) { base.updateKVBytesCapacity(bytes) }
    func shutdown() async { await base.shutdown() }
    func teacherForcedTop1(promptTokens: [Int], continuation: [Int]) throws -> [Int] { try base.teacherForcedTop1(promptTokens: promptTokens, continuation: continuation) }
    func prefillLogitDigest(_ promptTokens: [Int]) throws -> CBv2PrefillLogitDigest { try base.prefillLogitDigest(promptTokens) }
    func teacherForcedScoringActivity() -> CBv2TeacherForcedScoringActivity { base.teacherForcedScoringActivity() }
}
