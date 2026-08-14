// Copyright © 2026 Eigen Labs.
//
// Scan/advertise-time supported-set gate (v0.7.5): a model whose family has
// no CBv2 adapter is NEVER advertised — dropped at ProviderLoop init (the
// single chokepoint: coordinator registration filters through the advertised
// set, and the local /v1/models reads it) — and a load request for a
// dropped/stale id fails the advertised-set guard with a 404-mapped error,
// never a silent degrade. Coordinator `load_model` pushes for such an id
// get `load_model_status: failed`.

import Foundation
import Testing

@testable import ProviderCore

private func makeGateLoop(models: [ModelInfo]) throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546
        ),
        models: models,
        config: ProviderConfig(
            provider: ProviderSettings(name: "gate-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
}

private func modelInfo(id: String, modelType: String?) -> ModelInfo {
    ModelInfo(
        id: id, modelType: modelType, sizeBytes: 1 * 1024 * 1024 * 1024,
        estimatedMemoryGb: 1.2)
}

@Suite("EngineV2 supported-set advertise gate")
struct EngineV2SupportedSetGateTests {

    @Test("init drops unsupported families from the advertised set; supported ones stay")
    func initGateFiltersAdvertisedSet() async throws {
        let loop = try makeGateLoop(models: [
            modelInfo(id: "gpt-oss-20b", modelType: "gpt_oss"),
            modelInfo(id: "gemma-4-26b-qat-4bit", modelType: "gemma4"),
            modelInfo(id: "qwen3-8b", modelType: "qwen3"),          // no CBv2 adapter
            modelInfo(id: "gemma-3-legacy", modelType: "gemma3"),   // no CBv2 adapter
            modelInfo(id: "mystery-build", modelType: nil),         // unknown → fail closed
        ])
        #expect(await loop.isModelAdvertised("gpt-oss-20b"))
        #expect(await loop.isModelAdvertised("gemma-4-26b-qat-4bit"))
        #expect(await loop.isModelAdvertised("qwen3-8b") == false)
        #expect(await loop.isModelAdvertised("gemma-3-legacy") == false)
        #expect(await loop.isModelAdvertised("mystery-build") == false)
        #expect(await loop.advertisedModelCount() == 2)
    }

    @Test("partition splits supported/unsupported order-preserving")
    func partitionHelper() {
        let models = [
            modelInfo(id: "a", modelType: "gpt_oss"),
            modelInfo(id: "b", modelType: "qwen3"),
            modelInfo(id: "c", modelType: "gemma4_text"),
        ]
        let split = EngineV2SupportedModels.partition(models)
        #expect(split.supported.map(\.id) == ["a", "c"])
        #expect(split.unsupported.map(\.id) == ["b"])
    }

    @Test("load request for an unadvertised (unsupported/stale) id → 404-mapped error")
    func loadRequestForUnsupportedIdIs404() async throws {
        let loop = try makeGateLoop(models: [
            modelInfo(id: "qwen3-8b", modelType: "qwen3")  // dropped at init
        ])
        do {
            try await loop.ensureModelLoaded(modelId: "qwen3-8b")
            Issue.record("expected the load to fail")
        } catch {
            // Whichever guard fires first ("not found in cache" for a
            // fabricated id, or "not in advertised model list" for an
            // on-disk-but-unadvertised one), the mapping is 404 — the
            // coordinator drops the (provider, model) pair rather than
            // retrying a fault.
            #expect(ProviderLoop.loadErrorStatusCode(for: error) == 404)
        }
    }

    @Test("advertised-set guard message maps to 404 (stale-catalog contract)")
    func advertisedGuardMessageMapping() {
        // The two guard shapes ensureModelLoaded can throw for a stale id.
        #expect(ProviderLoop.loadErrorStatusCode(
            for: InferenceError.invalidModelDirectory(
                "Model 'x' not found in local HuggingFace cache")) == 404)
        #expect(ProviderLoop.loadErrorStatusCode(
            for: InferenceError.invalidModelDirectory(
                "Model 'x' not in advertised model list")) == 404)
        // Re-slice floor refusals surface as modelLoadFailed → 503
        // (transient capacity; the coordinator reroutes).
        #expect(ProviderLoop.loadErrorStatusCode(
            for: InferenceError.modelLoadFailed(
                "loading 'x' would re-slice some model's KV grant below the floor")) == 503)
    }

    @Test("model load failures preserve missing, pressure, and provider-fault wire semantics")
    func loadFailureWireClassification() {
        let cases: [(any Error, InferenceFailureCode, UInt16)] = [
            (
                InferenceError.invalidModelDirectory(
                    "Model 'x' not found in local HuggingFace cache"),
                .modelUnavailable,
                404
            ),
            (
                InferenceError.modelLoadFailed(
                    "Insufficient memory to load model"),
                .capacity,
                503
            ),
            (
                NSError(domain: "provider-load-fault", code: 1),
                .internalFailure,
                500
            ),
        ]
        for (error, expectedCode, expectedStatus) in cases {
            let failure = ProviderLoop.loadInferenceFailure(for: error)
            #expect(failure.code == expectedCode)
            #expect(failure.statusCode == expectedStatus)
            #expect(failure.errorReason == .modelLoad)
        }
    }

    @Test("coordinator load_model push for an unsupported id → load_model_status failed")
    func loadModelPushFailsLoudly() async throws {
        let loop = try makeGateLoop(models: [
            modelInfo(id: "qwen3-8b", modelType: "qwen3")
        ])
        let recorder = OutboundRecorder()
        let send = SendHandle { recorder.record($0) }
        await loop.handleLoadModelRequest(modelId: "qwen3-8b", send: send)

        // started fires immediately; failed follows once the load throws.
        for _ in 0..<400 {
            if recorder.statuses.contains(where: { $0.status == .failed }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let statuses = recorder.statuses
        #expect(statuses.first?.status == .started)
        #expect(statuses.contains { $0.status == .failed && $0.modelId == "qwen3-8b" })
        #expect(!statuses.contains { $0.status == .succeeded })
    }
}

/// Thread-safe outbound-message recorder for load_model_status assertions.
private final class OutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [OutboundMessage] = []
    var statuses: [(modelId: String, status: ProviderMessage.LoadModelStatus.Status)] {
        lock.withLock {
            _messages.compactMap {
                guard case .loadModelStatus(let modelId, let status, _) = $0 else { return nil }
                return (modelId, status)
            }
        }
    }
    func record(_ message: OutboundMessage) {
        lock.withLock { _messages.append(message) }
    }
}
