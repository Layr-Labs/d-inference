import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

/// T1-04: the attestation challenge is answered OFF the loop actor. The
/// serial event loop awaits `handleAttestationChallenge` inline, so its
/// cost is the time every later event (cancel, warm request, disconnect)
/// waits. With a runner that takes 250 ms per probe, the handler used to
/// block for the whole probe set; now the actor call returns at once and
/// both nonce-matched responses still arrive.
@Suite("Attestation challenge off the loop actor", .serialized)
struct AttestationChallengeOffActorTests {
    private struct SoftwareSigner: AttestationSigner {
        let key = P256.Signing.PrivateKey()
        var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }
        func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
    }

    private final class ResponseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var nonces: [String] = []
        func record(_ message: OutboundMessage) {
            if case .attestationResponse(let response) = message {
                lock.withLock { nonces.append(response.nonce) }
            }
        }
        var snapshot: [String] { lock.withLock { nonces } }
    }

    private func makeLoop(probeDelay: Duration) throws -> ProviderLoop {
        let slowRunner = SecurityCommandRunner { path, args in
            Thread.sleep(forTimeInterval: Double(probeDelay.components.seconds)
                + Double(probeDelay.components.attoseconds) / 1e18)
            switch (path, args) {
            case ("/usr/bin/csrutil", ["status"]):
                return SecurityCommandResult(terminationStatus: 0, stdout: "System Integrity Protection status: enabled.\n")
            case ("/usr/bin/csrutil", ["authenticated-root", "status"]):
                return SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: enabled\n")
            case ("/usr/bin/rdma_ctl", ["status"]):
                return SecurityCommandResult(terminationStatus: 0, stdout: "disabled\n")
            default:
                return SecurityCommandResult(terminationStatus: 0, stdout: "")
            }
        }
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "challenge-off-actor-test"),
                backend: BackendSettings(),
                coordinator: CoordinatorSettings()))
        return try ProviderLoop(
            config: config,
            purgeLegacyFiles: false,
            attestationSigner: SoftwareSigner(),
            securityCommandRunner: slowRunner)
    }

    @Test("two back-to-back challenges return from the actor immediately and both get nonce-matched responses")
    func challengesDoNotHoldTheLoopActor() async throws {
        let loop = try makeLoop(probeDelay: .milliseconds(250))
        let responses = ResponseRecorder()
        let send = SendHandle { responses.record($0) }

        let started = ContinuousClock.now
        await loop.handleAttestationChallenge(nonce: "bm9uY2UtYQ==", timestamp: "2026-09-03T00:00:00Z", send: send)
        await loop.handleAttestationChallenge(nonce: "bm9uY2UtYg==", timestamp: "2026-09-03T00:00:01Z", send: send)
        let heldForMs = ModelLoadStageReport.ms(.now - started)

        // Before T1-04 the first call alone blocked for ≥ 3 probes × 250 ms
        // (rdma_ctl + csrutil status + csrutil authenticated-root).
        #expect(heldForMs < 200, "handler held the actor for \(heldForMs) ms")

        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while responses.snapshot.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Set(responses.snapshot) == ["bm9uY2UtYQ==", "bm9uY2UtYg=="])
    }
}
