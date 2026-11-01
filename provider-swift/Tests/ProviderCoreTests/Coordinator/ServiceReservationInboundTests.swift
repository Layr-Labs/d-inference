import Foundation
import Testing

@testable import ProviderCore

@Suite("Service reservation settlement before handler dispatch")
struct ServiceReservationInboundTests {
    enum InvalidEnvelope: CaseIterable, Sendable {
        case plaintext, malformedCiphertext, malformedSender
    }

    @Test(arguments: InvalidEnvelope.allCases, [true, false])
    func invalidEnvelopeReleasesOnlyItsOpaqueReservation(
        envelope: InvalidEnvelope, identified: Bool
    ) async throws {
        let id = UUID().uuidString
        let body: EncryptedPayload? = switch envelope {
        case .plaintext: nil
        case .malformedCiphertext:
            .init(ephemeralPublicKey: Data(repeating: 0, count: 32).base64EncodedString(),
                ciphertext: "not-base64")
        case .malformedSender:
            .init(ephemeralPublicKey: Data([1]).base64EncodedString(),
                ciphertext: Data([1]).base64EncodedString())
        }
        let wire = try ProviderProtocolCodec.encodeCoordinatorMessage(.inferenceRequest(.init(
            requestId: "independent-client-request", encryptedBody: body,
            serviceReservationID: identified ? id : nil)))
        let released = await Self.releases(after: wire)
        #expect(released == (identified ? [id.lowercased()] : []))
    }

    /// A member without a live pair slot refuses a well-formed request on the
    /// receive path. The refused attempt can never acquire service, so it
    /// releases its reservation like an invalid envelope does.
    @Test(arguments: [true, false])
    func memberWithoutPairSlotReleasesItsReservation(identified: Bool) async throws {
        let id = UUID().uuidString
        let wire = try ProviderProtocolCodec.encodeCoordinatorMessage(.inferenceRequest(.init(
            requestId: "member-refused-request",
            encryptedBody: .init(ephemeralPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
                ciphertext: Data([1, 2, 3]).base64EncodedString()),
            serviceReservationID: identified ? id : nil)))
        let released = await Self.releases(after: wire, role: .clusterMember)
        #expect(released == (identified ? [id.lowercased()] : []))
    }

    private static func releases(after wire: Data, role: ProviderExecutionRole = .solo) async -> [String] {
        let client = CoordinatorClient(config: .init(
            url: "ws://unused.invalid/ws/provider",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: .init(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], backendName: "mlx-swift", publicKey: "unused", executionRole: role),
            stats: AtomicProviderStats(), state: ProviderState(), liveAPNsToken: { nil })
        let (outbound, continuation) = AsyncStream<OutboundMessage>.makeStream()
        let router = await client.outboundRouter
        router.activate(continuation)
        await client.handleIncomingFrame(wire, receivedAt: .now)
        continuation.finish()
        var released: [String] = []
        for await message in outbound {
            if case .serviceReservationReleased(let id) = message { released.append(id) }
        }
        return released
    }
}
