import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import XCTest

@testable import ProviderCore
@testable import MLXLLM

/// Private diagnostic, not an HTTP/transport or production qualification test.
/// The production loader, paged engine, sampler, admission and embedded head
/// execute unchanged. Only the existing explicit fixed-depth construction seam
/// and the private QSA switch differ. Run this test ALONE in the owned GPU lane.
final class Qwen4FixedDepthPerformanceProbeTests: XCTestCase {
    private struct Loaded: @unchecked Sendable {
        let model: any LanguageModel
        let tokenizer: any MLXLMCommon.Tokenizer
        let stops: Set<Int>
    }

    func testMatchedDepthsAndTargetOutputs() async throws {
        let env = ProcessInfo.processInfo.environment
        let axis = env["DARKBLOOM_QWEN4_FIXED_DEPTH_AXIS"] ?? "parallel"
        guard ["parallel", "layer"].contains(axis) else { throw ProbeFailure.identity }
        let layerAxis = axis == "layer"
        try XCTSkipUnless(env["DARKBLOOM_QWEN4_FIXED_DEPTH_PROBE"] == "1"
            && env["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1",
            "Explicit private diagnostic and exclusive GPU lane required")
        guard env["DARKBLOOM_PREFIX_CACHE"] == "0",
            env["DARKBLOOM_PREFIX_CACHE_MEMORY"] == "0",
            Qwen4ExpPLEResidency.useMmap, Qwen4ExpPLEResidency.retainCount == 0
        else { throw ProbeFailure.identity }
        let artifact = URL(fileURLWithPath: try XCTUnwrap(env["DARKBLOOM_QWEN4_REAL_MODEL"]))
        let input = URL(fileURLWithPath: try XCTUnwrap(env["DARKBLOOM_QWEN4_FIXED_DEPTH_INPUT"]))
        let output = URL(fileURLWithPath: try XCTUnwrap(env["DARKBLOOM_QWEN4_FIXED_DEPTH_OUTPUT"]))
        for url in [artifact, input, output] { XCTAssertTrue(url.path.hasPrefix("/")) }
        let config = try Data(contentsOf: artifact.appendingPathComponent("config.json"))
        let index = try Data(contentsOf: artifact.appendingPathComponent("model.safetensors.index.json"))
        guard hash(config) == "f04c5e8f500fe880617bf10a4ac6efc063b6ef8dbe66fb6a4843407c18ce7dae",
            hash(index) == "7fccee8cf9d3b2a7af16e34dec85ccd3558bb3aa7a399ab9eee2b3211cd8fbde"
        else { throw ProbeFailure.identity }
        let modelID = Qwen4SupportPolicy.ownedModelID
        let weightBytes = ModelScanner.collectWeightFiles(in: artifact).sizeBytes
        let paddedWeights = UInt64(Double(weightBytes) * 1.2)
        let capacity = UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes: paddedWeights)
        guard capacity >= 4 << 30,
            (SystemMemory.availableBytes() ?? 0) > paddedWeights + (4 << 30)
        else { throw ProbeFailure.memory }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let knobs = [Qwen4ExpParallelQSA.fullKVFlag, Qwen4ExpLayerSubmission.flag,
                     "DARKBLOOM_QWEN4_QSA_PARALLEL_VALUE_PARTITIONS"]
        defer {
            for knob in knobs {
                if let value = env[knob] { setenv(knob, value, 1) }
                else { unsetenv(knob) }
            }
            Qwen4ExpEnvironment.refresh()
        }
        let container = try await ModelContainerLoading.loadContainer(from: artifact, modelID: modelID)
        do {
            let loaded = try await container.perform { context -> Loaded in
                let native = try XCTUnwrap(context.model as? MLXVLM.Qwen4Exp)
                XCTAssertTrue(native.servesVision)
                let serving = try EngineV2Factory.benchmarkServingModel(
                    model: native, isVLM: true, modelDirectory: artifact)
                var stops = ModelEOSPolicy.effectiveEOSTokenIds(
                    modelId: modelID, modelType: "qwen4_exp",
                    base: context.configuration.eosTokenIds,
                    tokenToId: { context.tokenizer.convertTokenToId($0) })
                if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
                for name in context.configuration.extraEOSTokens {
                    if let token = context.tokenizer.convertTokenToId(name) { stops.insert(token) }
                }
                return Loaded(model: serving, tokenizer: context.tokenizer, stops: stops)
            }
            let inputData = try Data(contentsOf: input)
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: inputData) as? [String: Any])
            let fields = try XCTUnwrap(fixture["synthetic_request"] as? [String: Any])
            let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            guard request.model == modelID, request.temperature == 0,
                request.reasoning?.enabled == false, request.maxTokens == 192,
                request.tools == nil, request.messages.count == 1,
                request.messages[0].textContent.hasPrefix("Synthetic implementation fixture.")
            else { throw ProbeFailure.identity }
            let prompt = try ProviderPromptContractPipeline.tokenize(
                prepared: ToolChoicePromptPolicy.prepare(request), request: request,
                tokenizer: loaded.tokenizer, modelType: "qwen4_exp",
                templateControls: ProviderLoop.extractChatTemplateControls(from: body).resolvingPromptDate())
            guard prompt.count == 7041 else { throw ProbeFailure.identity }
            let head = try Qwen4ExpInlineMTPAssistant.load(from: artifact, target: loaded.model)
            guard let maximumDraftTokens = head.maximumDraftTokens, maximumDraftTokens >= 4,
                head.requiredVerificationMode == .rectangular
            else { throw ProbeFailure.depth }
            let budget = GlobalKVCacheBudget()
            var oracle: [Int]?
            var matched: [Int: [String: Any]] = [:]
            // Interleave both switch states; reverse depth/state order in repeat2.
            let order = [(false, 0), (false, 2), (true, 2), (true, 4), (false, 4), (true, 0),
                         (true, 0), (false, 4), (true, 4), (true, 2), (false, 2), (false, 0)]
            for (ordinal, arm) in order.enumerated() {
                let (enabled, depth) = arm
                let parallelEnabled = layerAxis || enabled
                let layerEnabled = layerAxis && enabled
                setenv(Qwen4ExpParallelQSA.fullKVFlag, parallelEnabled ? "1" : "0", 1)
                setenv(Qwen4ExpLayerSubmission.flag, layerEnabled ? "1" : "0", 1)
                setenv("DARKBLOOM_QWEN4_QSA_PARALLEL_VALUE_PARTITIONS", "32", 1)
                Qwen4ExpEnvironment.refresh()
                XCTAssertEqual(Qwen4ExpParallelQSA.fullKVEnabled(), parallelEnabled)
                let invocationStart = Qwen4ExpParallelQSAInvocation.snapshot()
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
                let start = ContinuousClock.now
                do {
                    for await event in try engine.submit(.init(id: .init(424242), promptTokens: prompt,
                        sampling: .init(temperature: 0, seed: 424242), maxTokens: 192,
                        stopTokens: loaded.stops, prefixCacheEnabled: false)) {
                        switch event {
                        case .delta(_, let values, _): tokens += values
                        case .finished(let reason, let value):
                            XCTAssertNil(finish, "Duplicate terminal")
                            finish = reason; usage = value
                        }
                    }
                } catch { await engine.shutdown(); throw error }
                let wall = seconds(start.duration(to: .now))
                let metrics = engine.mtpMetricsSnapshot()
                await engine.shutdown()
                Stream.gpu.synchronize()
                Stream.cpu.synchronize()
                let drain = engine.capacity()
                XCTAssertEqual(drain.activeRequests, 0)
                XCTAssertEqual(drain.waitingRequests, 0)
                XCTAssertEqual(drain.kvBytesReserved, 0)
                XCTAssertEqual(drain.kvBytesInUse, 0)
                let value = try XCTUnwrap(usage)
                let dispatches = Qwen4ExpParallelQSAInvocation.snapshot() - invocationStart
                let layerSubmissions = Qwen4ExpLayerSubmissionInvocation.snapshot() - layerStart
                XCTAssertEqual(finish, .length)
                XCTAssertEqual(value.completionTokens, 192)
                XCTAssertEqual(tokens.count, 192)
                XCTAssertEqual(hash(try canonical(tokens)),
                    "10b1b385bbd0179f529afa0c46b1064397bde3844c8b73ae41dcdfe7897608b5",
                    "Must also match the independently completed pre-scheduling target oracle")
                XCTAssertEqual(value.prefixCachePrefillTokensSaved, 0)
                if let oracle { XCTAssertEqual(tokens, oracle, "Exact target output changed") }
                else { oracle = tokens }
                XCTAssertEqual(dispatches > 0, parallelEnabled)
                XCTAssertEqual(layerSubmissions > 0, layerEnabled)
                var semantic: [String: Any] = ["rounds": 0, "proposed": 0, "accepted": 0]
                if depth > 0 {
                    let mtp = try XCTUnwrap(metrics)
                    XCTAssertEqual(mtp.verificationMode, .rectangular)
                    XCTAssertGreaterThan(mtp.rounds, 0)
                    XCTAssertEqual(mtp.serialVerificationRounds, 0)
                    XCTAssertGreaterThan(mtp.depthSelections[depth, default: 0], 0)
                    XCTAssertTrue(mtp.depthSelections.keys.allSatisfy { $0 <= depth })
                    XCTAssertTrue(mtp.costInputs.allSatisfy { $0.depth <= depth })
                    semantic = ["rounds": mtp.rounds, "proposed": mtp.proposedTokens,
                        "accepted": mtp.acceptedTokens, "per_position_accepted": mtp.perPositionAccepted,
                        "conditional_acceptance": mtp.conditionalAcceptance,
                        "depth_selections": Dictionary(uniqueKeysWithValues:
                            mtp.depthSelections.map { (String($0.key), $0.value) }),
                        "fallbacks": mtp.controllerFallbacks, "skipped": mtp.skippedRows]
                    if let previous = matched[depth] {
                        XCTAssertEqual(try canonical(semantic), try canonical(previous),
                            "Fixed-depth proposal/acceptance/selection trace changed")
                    } else { matched[depth] = semantic }
                } else { XCTAssertNil(metrics) }
                let timing = value.timing
                guard timing.finishedNanos > timing.firstTokenNanos,
                    timing.promptComputedNanos > timing.prefillFirstLaunchNanos
                else { throw ProbeFailure.timing }
                let decode = Double(value.completionTokens - 1) * 1e9
                    / Double(timing.finishedNanos - timing.firstTokenNanos)
                let prefill = Double(prompt.count) * 1e9
                    / Double(timing.promptComputedNanos - timing.prefillFirstLaunchNanos)
                let receipt: [String: Any] = ["ordinal": ordinal, "axis": axis,
                    "optimization_enabled": enabled, "parallel_full_kv": parallelEnabled,
                    "layer_async": layerEnabled, "early_layer_submissions": layerSubmissions,
                    "fixed_depth": depth, "repetition": ordinal / 6 + 1,
                    "prompt_tokens": prompt.count, "completion_tokens": value.completionTokens,
                    "prompt_sha256": hash(try canonical(prompt)), "output_sha256": hash(try canonical(tokens)),
                    "input_fixture_sha256": hash(inputData), "config_sha256": hash(config), "index_sha256": hash(index),
                    "native_decode_tps": decode, "native_prefill_tps": prefill,
                    "wall_seconds": wall, "prefill_chunks": timing.prefillChunks,
                    "chained_decode_steps": timing.chainedDecodeSteps, "parallel_invocations": dispatches,
                    "mtp": semantic, "paged_native_memory_owner": build.usesProcessMemoryOwner,
                    "scope": "Direct production-engine fixed-depth diagnostic; not HTTP, hosted OR or full qualification"]
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent(String(format: "%02d.json", ordinal)), options: .atomic)
                print("[qwen4-fixed-depth] arm=\(ordinal) axis=\(axis) enabled=\(enabled) depth=\(depth) decode_tps=\(decode) prefill_tps=\(prefill) output_tokens=\(tokens.count) parallel_dispatches=\(dispatches) early_submissions=\(layerSubmissions)")
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
    private func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }
    private enum ProbeFailure: Error { case identity, memory, depth, timing }
}
