// Copyright © 2026 Eigen Labs.
//
// A cancel honored INSIDE the model-load window — the request was accepted,
// `ensureModelLoaded` is still running, and no generation task exists yet —
// must still produce a terminal: exactly one 499 `cancelled` inference_error
// carrying the request's profile, and zero chunks. Both load-window guards
// used to return silently, so the coordinator could never measure
// cancel→terminal latency for exactly the head-of-line-blocked case it most
// needs to see.
//
// Live-isolated: a real `ProviderLoop` over the real `handleInferenceRequest`
// path (sealed body, admission, accept, cancellation registry), parked on the
// real `loadingWaiters` continuation; only the weights are stubbed.

import Foundation
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

// MARK: - Stub container (never forward-passed)

private final class CancelLoadStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct CancelLoadStubProcessorError: Error {}

private struct CancelLoadStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw CancelLoadStubProcessorError()
    }
}

private func makeCancelLoadStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/stub-model"),
            model: CancelLoadStubLanguageModel(),
            processor: CancelLoadStubProcessor(),
            tokenizer: StubBridgeTokenizer()
        ))
}

// MARK: - Outbound recorder

private final class OutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []

    func append(_ message: OutboundMessage) {
        lock.withLock { messages.append(message) }
    }

    var kinds: [String] {
        lock.withLock {
            messages.map {
                switch $0 {
                case .inferenceAccepted: return "accepted"
                case .inferenceChunk: return "chunk"
                case .inferenceComplete: return "complete"
                case .inferenceError: return "error"
                default: return "other"
                }
            }
        }
    }

    var errors: [(failure: InferenceFailure, profile: RequestProfileBuilder?)] {
        lock.withLock {
            messages.compactMap {
                if case .inferenceError(_, let failure, let profile) = $0 {
                    return (failure, profile)
                }
                return nil
            }
        }
    }
}

@Suite("ProviderLoop cancellation inside the model-load window")
struct ProviderLoopCancelDuringLoadTests {

    private func makeLoop() throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5",
                chipName: "Apple M4 Max",
                chipFamily: .m4,
                chipTier: .max,
                memoryGb: 128,
                memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40,
                memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "cancel-in-load-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(
            config: config,
            purgeLegacyFiles: false,
            attestationSigner: nil)
    }

    @Test("a cancel honored inside the load window emits exactly one 499 terminal with the profile and zero chunks")
    func cancelDuringLoadEmitsSingle499Terminal() async throws {
        let loop = try makeLoop()
        let modelId = "stub-model"
        let requestId = "req-cancel-in-load"
        await loop.beginSimulatedModelLoadForTesting(modelId: modelId)

        // Seal the body exactly as the coordinator does.
        let sender = NodeKeyPair.generate()
        let senderPublicKey = sender.publicKeyBytes
        let body = Data(
            #"{"model":"stub-model","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let ciphertext = try sender.encrypt(
            recipientPublicKey: await loop.publicKeyBytesForTesting(),
            plaintext: body)

        let recorder = OutboundRecorder()
        let handler = Task {
            await loop.handleInferenceRequest(
                requestId: requestId,
                ciphertext: ciphertext,
                senderPublicKey: senderPublicKey,
                cacheReceiptNonce: nil,
                authenticatedCacheScope: nil,
                send: SendHandle(recorder.append))
        }

        // The request is accepted and parked in the load window.
        var attempts = 0
        while await loop.loadWaiterCountForTesting(modelId: modelId) == 0, attempts < 20_000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await loop.loadWaiterCountForTesting(modelId: modelId) == 1)
        #expect(recorder.kinds == ["accepted"])
        #expect(await loop.hasInflightWork)
        let cancelDuringLoadBefore = await loop.stats.cancelDuringModelLoad

        // The coordinator's cancel lands while the load is still running.
        await loop.handleCancellation(requestId: requestId)
        #expect(
            recorder.kinds == ["accepted"],
            "the terminal is owed by the request handler once the load returns, not by the cancel")
        #expect(await loop.stats.cancelDuringModelLoad == cancelDuringLoadBefore + 1)

        // The load completes AFTER the cancel: install the slot, resume.
        let (bridge, engine) = makeInertStubBridge(modelId: modelId)
        await loop.installModelSlotForTesting(
            modelId: modelId,
            container: makeCancelLoadStubContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            engineV2: bridge)
        await loop.finishSimulatedModelLoadForTesting(modelId: modelId)
        await handler.value

        // Exactly one terminal, the pre-output cancel shape, and no chunks.
        #expect(recorder.kinds == ["accepted", "error"])
        let (failure, profile) = try #require(recorder.errors.first)
        #expect(failure.statusCode == 499)
        #expect(failure.code == .cancelled)
        #expect(failure.terminalCause == .cancelled)
        #expect(failure.attemptUsage == nil)
        #expect(await loop.hasInflightWork == false)
        #expect(await bridge._testCounters().active == 0, "no engine submit for a cancelled request")
        withExtendedLifetime(engine) {}
        // The profile rides the terminal with the cancel stamps in order, so
        // the coordinator can measure cancel→terminal latency for the
        // head-of-line-blocked case.
        let wire = try #require(profile?.wireObject())
        #expect(wire.cancelStage != nil)
        #expect(wire.cancelReceivedUs != nil)
        #expect(wire.cancelAbortedUs != nil)
        #expect(wire.terminalBuiltUs != nil)
    }
}
