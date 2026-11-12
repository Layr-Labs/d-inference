import CryptoKit
import Darwin
import Foundation
import Network
import Testing
import DarkbloomClusterSecurity
@testable import ProviderCore

@Suite("Native member binding and bounded control", .serialized)
struct NativePairMemberControlTests {
    @Test func approvalAndOriginalDeadlineBindingsRejectSubstitutionAndOverflow() throws {
        let fixture = try NativePairMemberFixture()
        let policy = try NativePairMemberPolicy(fixture.policy)
        try policy.require(fixture.starts[0])
        for raw in [Data(fixture.policy.dropLast()), fixture.policy + Data([0]), Data()] {
            #expect(throws: NativePairMemberError.self) { _ = try NativePairMemberPolicy(raw) }
        }
        var replacement = fixture.policy
        let index = Data("darkbloom/coordinator-native-runtime-approval/v1\0".utf8).count + 4
        replacement[index] ^= 1 // Valid alternate ID; its digest is not approved by start.
        let other = try NativePairMemberPolicy(replacement)
        #expect(throws: NativePairMemberError.self) { try other.require(fixture.starts[0]) }
        let connection = NativePairMemberConnection(nonce: String(repeating: "45", count: 32),
            connection: .init(host: "127.0.0.1", port: 9, using: .tcp), signer: MemberFixtureSigner(), onInvalidation: { _ in })
        defer { connection.invalidate() }
        let message = try fixture.message("native_pair_prepare", rank: 0, nonce: connection.nonce, sequence: 1)
        #expect(throws: NativePairMemberError.self) {
            _ = try NativePairMemberSession(installation: fixture.installations[0], connection: connection, message: message,
                receivedAt: UInt64.max - 1, wallUnixNanoseconds: fixture.prepareUnix - 1) { _, _ in }
        }
        #expect(throws: NativePairMemberError.self) {
            _ = try NativePairMemberSession(installation: fixture.installations[0], connection: connection, message: message,
                receivedAt: DispatchTime.now().uptimeNanoseconds, wallUnixNanoseconds: fixture.prepareUnix) { _, _ in }
        }
        let changedGeneration = try NativePairMessage(type: message.type, memberNonce: message.memberNonce,
            epoch: message.epoch, generation: 8, sequence: message.sequence, payload: #require(Data(base64Encoded: message.payload)),
            prepareBeforeUnixNano: fixture.prepareUnix, expiresAtUnixNano: fixture.expiresUnix)
        #expect(throws: NativePairMemberError.self) {
            _ = try NativePairMemberSession(installation: fixture.installations[0], connection: connection, message: changedGeneration,
                receivedAt: DispatchTime.now().uptimeNanoseconds, wallUnixNanoseconds: fixture.prepareUnix - 1) { _, _ in }
        }
        #expect(fixture.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("native-started").path) })
    }

    @Test func writerAcquisitionExpiresWhileSignerIsBlockedWithoutPublishing() async throws {
        let signer = MemberFixtureSigner(); signer.pause(onCall: 1)
        let invalidated = DispatchGroup(); invalidated.enter()
        let finished = DispatchGroup(); finished.enter()
        let connection = NativePairMemberConnection(nonce: String(repeating: "67", count: 32),
            connection: .init(host: "127.0.0.1", port: 9, using: .tcp), signer: signer,
            onInvalidation: { _ in invalidated.leave() })
        defer { signer.resume(); connection.invalidate() }
        DispatchQueue.global().async {
            defer { finished.leave() }
            try? connection.send(type: "native_pair_cancel", epoch: String(repeating: "78", count: 16),
                generation: 1, payload: Data([68, 66, 78, 67, 1]), until: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        }
        try await waitUntil { signer.isPaused }
        let began = DispatchTime.now().uptimeNanoseconds
        #expect(throws: NativePairMemberError.self) {
            try connection.send(type: "native_pair_cancel", epoch: String(repeating: "78", count: 16),
                generation: 1, payload: Data([68, 66, 78, 67, 1]), until: began + 30_000_000)
        }
        #expect(DispatchTime.now().uptimeNanoseconds - began < 500_000_000)
        #expect(!connection.isLive && isComplete(invalidated))
        #expect(!isComplete(finished)) // Signer has not returned.
        signer.resume()
        try await waitUntil { finished.wait(timeout: .now()) == .success }
    }

    @Test func stalledHelloSignerCannotDelayActualNativeCleanupOrEnableReleaseOnNewConnection() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        peer.signer.pause(onCall: 2)
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            try await waitUntil { peer.signer.isPaused }
            #expect(FileManager.default.fileExists(atPath: fixture.directories[0].appendingPathComponent("native-started").path))
            peer.control.detach(peer.context)
            try await waitUntil {
                let journal = fixture.directories[0].appendingPathComponent(".darkbloom/cluster-device/native-device.lease")
                return (try? Data(contentsOf: journal).isEmpty) == true
            }
            try fixture.requireRetired(0, confirmed: false)
            #expect(peer.signer.isPaused && peer.control.status == "quarantined")
            #expect(peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared"])
            #expect(throws: NativePairMemberError.self) {
                _ = try peer.control.attach(nonce: String(repeating: "89", count: 32),
                    connection: .init(host: "127.0.0.1", port: 9, using: .tcp))
            }
            peer.signer.resume()
            await peer.close()
        } catch { peer.signer.resume(); await peer.close(); throw error }
    }

    private func isComplete(_ group: DispatchGroup) -> Bool {
        group.wait(timeout: .now()) == .success
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
