// Copyright © 2026 Eigen Labs.
//
// Encrypted coordinator ingress: a decision body routed to a chat model, or a
// chat body routed to a decision model, is refused with a content-free 400
// before `inference_accepted`, a model load or any engine work.

import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Coordinator decision admission")
struct DecisionCoordinatorAdmissionTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [OutboundMessage] = []
        func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
        var snapshot: [OutboundMessage] { lock.withLock { messages } }
    }

    private static let chatModel = "test/chat-qwen"
    private static let decisionModel = "test/decider"

    private func makeLoop() throws -> ProviderLoop {
        let info = { (id: String, type: String) in
            ModelInfo(id: id, modelType: type, sizeBytes: 1 << 30, estimatedMemoryGb: 1.2)
        }
        return try ProviderLoop(
            config: .init(
                coordinatorURL: "ws://127.0.0.1:0/unused",
                hardware: HardwareInfo(
                    machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                    memoryGb: 128, memoryAvailableGb: 124,
                    cpuCores: .init(total: 16, performance: 12, efficiency: 4),
                    gpuCores: 40, memoryBandwidthGbs: 546),
                models: [info(Self.chatModel, "qwen3_5"), info(Self.decisionModel, "pplx_decider_qwen35")],
                config: .init(
                    provider: .init(name: "decision-admission-test", memoryReserveGB: 1),
                    backend: .init(idleTimeoutMins: 0, maxModelSlots: 1),
                    coordinator: .init(heartbeatIntervalSecs: 60))),
            attestationSigner: nil)
    }

    private func send(_ body: Data, to loop: ProviderLoop) async throws -> (failures: [InferenceFailure], accepted: Bool) {
        let recorder = Recorder()
        let sender = NodeKeyPair.generate()
        let requestID = "decision-admission-" + UUID().uuidString
        let encrypted = try sender.encrypt(
            recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: body)
        await loop.handleInferenceRequest(
            requestId: requestID, ciphertext: encrypted, senderPublicKey: sender.publicKeyBytes,
            cacheReceiptNonce: nil, authenticatedCacheScope: nil, prefixCacheProtocol: 2,
            send: SendHandle(recorder.record))
        var failures: [InferenceFailure] = []
        var accepted = false
        for message in recorder.snapshot {
            if case .inferenceError(_, let failure, _) = message { failures.append(failure) }
            if case .inferenceAccepted = message { accepted = true }
        }
        #expect(await loop.requestToModel[requestID] == nil)
        return (failures, accepted)
    }

    @Test("a decision body to a chat model is refused before acceptance")
    func decisionToChatModel() async throws {
        let loop = try makeLoop()
        let body = #"{"model": "\#(Self.chatModel)", "state": "s", "questions": {"q": {"type": "noul"}}}"#
        let result = try await send(Data(body.utf8), to: loop)
        #expect(!result.accepted)
        #expect(result.failures.map(\.statusCode) == [400])
        #expect(result.failures.first?.code == .invalidRequest)
        #expect(await loop.modelSlots.isEmpty)
    }

    @Test("a chat body to a decision model is refused before acceptance")
    func chatToDecisionModel() async throws {
        let loop = try makeLoop()
        let chat = OpenAIChatCompletionRequest(
            model: Self.decisionModel, messages: [OpenAIChatMessage(role: .user, content: .text("hi"))])
        let result = try await send(try JSONEncoder().encode(chat), to: loop)
        #expect(!result.accepted)
        #expect(result.failures.map(\.statusCode) == [400])
        #expect(result.failures.first?.code == .invalidRequest)
        #expect(await loop.modelSlots.isEmpty)
    }

    @Test("a body that is neither chat nor a valid decision stays a plain 400")
    func malformedDecisionBody() async throws {
        let loop = try makeLoop()
        let body = #"{"model": "\#(Self.decisionModel)", "state": "s", "questions": {"q": {"type": "rank"}}}"#
        let result = try await send(Data(body.utf8), to: loop)
        #expect(!result.accepted)
        #expect(result.failures.map(\.statusCode) == [400])
    }
}
