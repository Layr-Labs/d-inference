import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// A coordinator request carrying a content part type no engine serves is refused before acceptance or any model
/// load, on one Mac and on a pair member alike, as the local API refuses it (never answered from the text that is
/// left). The refusal is the closed invalid-request failure: no part type or other request content crosses to the
/// coordinator.
@Suite("Unsupported content part ingress")
struct UnsupportedContentPartIngressTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [OutboundMessage] = []
        private var builds = 0
        func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
        func recordBuild() { lock.withLock { builds += 1 } }
        var snapshot: [OutboundMessage] { lock.withLock { messages } }
        var buildCount: Int { lock.withLock { builds } }
    }

    @Test("an unknown part type refuses before acceptance", arguments: ["input_file", "input_video", "refusal"])
    func refusedBeforeAcceptance(type: String) async throws {
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(
            config: .init(
                coordinatorURL: "ws://127.0.0.1:0/unused", hardware: hardware, models: [],
                config: .init(
                    provider: .init(name: "content-part-ingress-test", memoryReserveGB: 1),
                    backend: .init(idleTimeoutMins: 0, maxModelSlots: 1),
                    coordinator: .init(heartbeatIntervalSecs: 60))), attestationSigner: nil)
        let probe = Probe()
        await loop.setEngineV2SlotHooksForTesting(
            .init(makeEngine: { _, _ in
                probe.recordBuild()
                return InertStubEngine()
            }))
        let body = Data(#"{"model":"test/absent-model-\#(UUID().uuidString)","messages":[{"role":"user","content":[{"type":"text","text":"Summarize it."},{"type":"\#(type)","file_id":"file-fixture"}]}]}"#.utf8)
        let requestID = "content-part-" + UUID().uuidString
        let reservationID = UUID().uuidString.lowercased()
        let sender = NodeKeyPair.generate()
        let encrypted = try sender.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: body)
        let profile = RequestProfileBuilder()
        await loop.handleInferenceRequest(
            requestId: requestID, ciphertext: encrypted,
            senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: "content-part-nonce",
            authenticatedCacheScope: "content-part-scope", prefixCacheProtocol: 2,
            cacheReceiptBoundaryMode: "checkpoint", profile: profile,
            serviceReservationID: reservationID, send: SendHandle(probe.record))

        var kinds: [String] = []
        var failures: [InferenceFailure] = []
        for message in probe.snapshot {
            switch message {
            case .inferenceError(let id, let failure, _):
                kinds.append("error")
                #expect(id == requestID)
                failures.append(failure)
            case .serviceReservationReleased(let id):
                kinds.append("released")
                #expect(id == reservationID)
            default:
                kinds.append("unexpected")
            }
        }
        #expect(kinds == ["error", "released"])
        let failure = try #require(failures.first)
        #expect(failure.statusCode == 400)
        #expect(failure.code == .invalidRequest)
        #expect(failure.message == InferenceFailureCode.invalidRequest.message)
        #expect(!failure.message.contains(type))
        let observed = profile.wireObject()
        #expect(observed.parsedUs != nil && observed.acceptedSentUs == nil && observed.loadWaitStartUs == nil)
        #expect(probe.buildCount == 0)
        #expect(await loop.modelSlots.isEmpty)
        #expect(await loop.modelsLoading.isEmpty)
        #expect(await loop.acceptedLifecycleRequests.isEmpty)
    }
}
