import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import XCTest

@testable import MLXLLM
@testable import ProviderCore

/// Opt-in selected-artifact diagnostic. It compares the original explicit-OFF
/// arithmetic, old explicit-ON profile and genuinely unset new defaults. It is
/// not an HTTP, physical hardware-tier or universal performance certificate.
final class Qwen4DefaultProfilePerformanceTests: XCTestCase {
    private struct Loaded: @unchecked Sendable {
        let model: any LanguageModel
        let tokenizer: any MLXLMCommon.Tokenizer
        let stops: Set<Int>
    }

    func testSelectedArtifactDefaultProfileMatchesExplicitArms() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DARKBLOOM_QWEN4_DEFAULT_PROFILE_PERF"] == "1"
            && env["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1",
            "Requires the explicit selected-artifact diagnostic and exclusive GPU lane")
        XCTAssertEqual(env["DARKBLOOM_PREFIX_CACHE"], "0")
        XCTAssertEqual(env["DARKBLOOM_PREFIX_CACHE_MEMORY"], "0")
        XCTAssertTrue(Qwen4ExpPLEResidency.useMmap)
        XCTAssertEqual(Qwen4ExpPLEResidency.retainCount, 0)
        let artifact = URL(fileURLWithPath: try XCTUnwrap(env["DARKBLOOM_QWEN4_REAL_MODEL"]))
        let output = URL(fileURLWithPath: try XCTUnwrap(env["DARKBLOOM_QWEN4_DEFAULT_PROFILE_OUTPUT"]))
        XCTAssertTrue(artifact.path.hasPrefix("/")); XCTAssertTrue(output.path.hasPrefix("/"))
        let config = try Data(contentsOf: artifact.appendingPathComponent("config.json"))
        let index = try Data(contentsOf: artifact.appendingPathComponent("model.safetensors.index.json"))
        guard hash(config) == "319b334a1abb705acf06035aa0331bcb7c25976ff93a5035b543548738a10824",
            hash(index) == "05f70b017f328d7d9f955186bd9868d1f5c3fb708df89cd47d7d1c14b73b73d2"
        else { throw ProbeFailure.identity }
        let modelID = Qwen4SupportPolicy.ownedModelID
        let paddedWeights = UInt64(Double(ModelScanner.collectWeightFiles(in: artifact).sizeBytes) * 1.2)
        let capacity = UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes: paddedWeights)
        guard capacity >= 4 << 30, (SystemMemory.availableBytes() ?? 0) > paddedWeights + (4 << 30)
        else { throw ProbeFailure.memory }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let knobs = [Qwen4ExpParallelQSA.fullKVFlag, Qwen4ExpLayerSubmission.flag,
                     Qwen4ExpParallelQSA.valuePartitionsFlag]
        defer {
            for knob in knobs {
                if let value = env[knob] { setenv(knob, value, 1) } else { unsetenv(knob) }
            }
            Qwen4ExpEnvironment.refresh()
        }
        let container = try await ModelContainerLoading.loadContainer(from: artifact, modelID: modelID)
        do {
            let loaded = try await container.perform { context -> Loaded in
                let native = try XCTUnwrap(context.model as? MLXVLM.Qwen4Exp)
                XCTAssertTrue(native.servesVision)
                let model = try EngineV2Factory.benchmarkServingModel(
                    model: native, isVLM: true, modelDirectory: artifact)
                var stops = ModelEOSPolicy.effectiveEOSTokenIds(
                    modelId: modelID, modelType: "qwen4_exp", base: context.configuration.eosTokenIds,
                    tokenToId: { context.tokenizer.convertTokenToId($0) })
                if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
                for name in context.configuration.extraEOSTokens {
                    if let token = context.tokenizer.convertTokenToId(name) { stops.insert(token) }
                }
                return Loaded(model: model, tokenizer: context.tokenizer, stops: stops)
            }
            let head = try Qwen4ExpInlineMTPAssistant.load(from: artifact, target: loaded.model)
            guard let maximum = head.maximumDraftTokens, maximum >= 4,
                head.requiredVerificationMode == .rectangular else { throw ProbeFailure.depth }
            var log = "Read this synthetic maintenance log.\n"
            for i in 0..<180 {
                log += "Entry \(i): sensor \(i % 17) reported value \(i * 37 % 1000) at tick \(i * 13).\n"
            }
            log += "Summarize the log in two concise sentences."
            let body = try canonical(["model": modelID, "temperature": 0, "seed": 0, "max_tokens": 64,
                "messages": [["role": "user", "content": log]],
                "chat_template_kwargs": ["enable_thinking": false]])
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            let prompt = try ProviderPromptContractPipeline.tokenize(
                prepared: ToolChoicePromptPolicy.prepare(request), request: request,
                tokenizer: loaded.tokenizer, modelType: "qwen4_exp",
                templateControls: ProviderLoop.extractChatTemplateControls(from: body).resolvingPromptDate())
            XCTAssertEqual(prompt.count, 4207, "Use the same committed maintenance-log workload")
            let budget = GlobalKVCacheBudget()
            var oracle: [Int]?
            var traces: [Int: Data] = [:]
            let arms = [("off", 0), ("on", 0), ("unset", 0), ("off", 2), ("on", 2),
                        ("unset", 2), ("off", 4), ("on", 4), ("unset", 4)]
            // Repeat in reverse order; retain first-run timing separately.
            let order = [("off", 0)] + arms + arms.reversed()
            for (ordinal, arm) in order.enumerated() {
                let (profile, depth) = arm
                for knob in knobs { unsetenv(knob) }
                if profile != "unset" {
                    setenv(Qwen4ExpParallelQSA.fullKVFlag, profile == "on" ? "1" : "0", 1)
                    setenv(Qwen4ExpLayerSubmission.flag, profile == "on" ? "1" : "0", 1)
                    if profile == "on" { setenv(Qwen4ExpParallelQSA.valuePartitionsFlag, "32", 1) }
                }
                Qwen4ExpEnvironment.refresh()
                let parallelStart = Qwen4ExpParallelQSAInvocation.snapshot()
                let layerStart = Qwen4ExpLayerSubmissionInvocation.snapshot()
                let build = try EngineV2Factory.makeProductionBuild(
                    model: loaded.model, modelID: modelID, tokenizer: loaded.tokenizer,
                    kvBytesCapacity: Int(capacity), maxConcurrentRequests: 1, kvBudget: budget,
                    mtpDrafter: depth == 0 ? nil : head,
                    mtpConfig: .init(enabled: depth > 0, maxDraftTokens: 4, maxSpeculativeBatch: 1,
                        fixedDraftTokens: depth, verificationMode: .rectangular),
                    kvBackend: .paged, maxContextLength: 16384)
                let engine = try XCTUnwrap(build.engine as? EngineV2)
                XCTAssertEqual(build.kvBackendKind, .paged)
                XCTAssertTrue(build.usesProcessMemoryOwner)
                var tokens: [Int] = []
                var usage: CBv2Usage?
                var finish: CBv2FinishReason?
                do {
                    for await event in try engine.submit(.init(id: .init(424242), promptTokens: prompt,
                        sampling: .init(temperature: 0, seed: 0), maxTokens: 64,
                        stopTokens: loaded.stops, prefixCacheEnabled: false)) {
                        switch event {
                        case .delta(_, let values, _): tokens += values
                        case .finished(let reason, let value):
                            XCTAssertNil(finish); finish = reason; usage = value
                        }
                    }
                } catch { await engine.shutdown(); throw error }
                let metrics = engine.mtpMetricsSnapshot()
                await engine.shutdown()
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                let drain = engine.capacity()
                XCTAssertEqual(drain.activeRequests, 0); XCTAssertEqual(drain.waitingRequests, 0)
                XCTAssertEqual(drain.kvBytesReserved, 0); XCTAssertEqual(drain.kvBytesInUse, 0)
                let value = try XCTUnwrap(usage)
                XCTAssertEqual(finish, .length); XCTAssertEqual(tokens.count, 64)
                XCTAssertEqual(value.completionTokens, 64)
                XCTAssertEqual(value.prefixCachePrefillTokensSaved, 0)
                if let oracle { XCTAssertEqual(tokens, oracle, "Exact target token IDs changed") }
                else { oracle = tokens }
                let parallel = Qwen4ExpParallelQSAInvocation.snapshot() - parallelStart
                let layers = Qwen4ExpLayerSubmissionInvocation.snapshot() - layerStart
                XCTAssertEqual(parallel > 0, profile != "off")
                XCTAssertEqual(layers > 0, profile != "off")
                var semantic: [String: Any] = ["rounds": 0, "proposed": 0, "accepted": 0]
                if depth > 0 {
                    let mtp = try XCTUnwrap(metrics)
                    XCTAssertGreaterThan(mtp.rounds, 0)
                    XCTAssertEqual(mtp.serialVerificationRounds, 0)
                    XCTAssertEqual(mtp.verificationMode, .rectangular)
                    XCTAssertGreaterThan(mtp.depthSelections[depth, default: 0], 0)
                    XCTAssertTrue(mtp.depthSelections.keys.allSatisfy { $0 <= depth })
                    semantic = ["rounds": mtp.rounds, "proposed": mtp.proposedTokens,
                        "accepted": mtp.acceptedTokens, "per_position_accepted": mtp.perPositionAccepted,
                        "conditional_acceptance": mtp.conditionalAcceptance,
                        "depth_selections": Dictionary(uniqueKeysWithValues:
                            mtp.depthSelections.map { (String($0.key), $0.value) }),
                        "fallbacks": mtp.controllerFallbacks, "skipped": mtp.skippedRows]
                    let trace = try canonical(semantic)
                    if let previous = traces[depth] { XCTAssertEqual(trace, previous, "Fixed-depth acceptance trace changed") }
                    else { traces[depth] = trace }
                } else { XCTAssertNil(metrics) }
                let timing = value.timing
                guard timing.finishedNanos > timing.firstTokenNanos,
                    timing.promptComputedNanos > timing.prefillFirstLaunchNanos else { throw ProbeFailure.timing }
                let prefill = Double(prompt.count) * 1e9 / Double(timing.promptComputedNanos - timing.prefillFirstLaunchNanos)
                let decode = Double(value.completionTokens - 1) * 1e9 / Double(timing.finishedNanos - timing.firstTokenNanos)
                let receipt: [String: Any] = ["ordinal": ordinal, "warmup": ordinal == 0,
                    "profile": profile, "fixed_depth": depth, "prompt_tokens": prompt.count,
                    "completion_tokens": tokens.count, "output_sha256": hash(try canonical(tokens)),
                    "prompt_sha256": hash(try canonical(prompt)), "config_sha256": hash(config), "index_sha256": hash(index),
                    "native_prefill_tps": prefill, "native_decode_tps": decode, "prefill_chunks": timing.prefillChunks,
                    "parallel_invocations": parallel, "early_layer_submissions": layers, "mtp": semantic]
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent(String(format: "%02d.json", ordinal)), options: .atomic)
                print("[qwen4-default-profile] arm=\(ordinal) profile=\(profile) depth=\(depth) prefill_tps=\(prefill) decode_tps=\(decode) parallel=\(parallel) layer_submissions=\(layers)")
            }
            await ModelContainerLoading.releaseExternalResources(in: container)
        } catch {
            await ModelContainerLoading.releaseExternalResources(in: container)
            throw error
        }
        XCTAssertEqual(Qwen4ExpPLEResidency.retainCount, 0)
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func hash(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
    private enum ProbeFailure: Error { case identity, memory, depth, timing }
}
