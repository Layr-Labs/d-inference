import CryptoKit
import Darwin
import Foundation
import Network
import Testing
import DarkbloomClusterSecurity
@testable import ProviderCore

@Suite("Owned native member invocation", .serialized)
struct NativePairMemberInvocationTests {
    @Test func actualBilateralNativePreludeRequiresCommitAndReleasesOnlyAfterOwners() async throws {
        let fixture = try NativePairMemberFixture()
        let peers = fixture.installations.map(MemberFixturePeer.init)
        do {
            for peer in peers { try await peer.connect() }
            for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_prepare", rank: rank, nonce: peers[rank].nonce, sequence: 1)) }
            for rank in 0..<2 {
                let prepared = try await peers[rank].wait("native_pair_prepared")
                #expect(Data(base64Encoded: prepared.payload) == fixture.starts[rank].canonicalBytes)
                // A real public prepared response is the causal barrier; no sleeps.
                #expect(!FileManager.default.fileExists(atPath: fixture.directories[rank].appendingPathComponent("native-started").path))
                #expect(peers[rank].mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared"])
            }
            for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_owner_start", rank: rank, nonce: peers[rank].nonce, sequence: 2)) }
            var hellos: [ClusterNativeKeyHello] = []
            for rank in 0..<2 {
                let message = try await peers[rank].wait("native_pair_hello")
                let hello = try ClusterNativeKeyHello(encoded: #require(Data(base64Encoded: message.payload)))
                #expect(hello.start.canonicalBytes == fixture.starts[rank].canonicalBytes)
                hellos.append(hello)
            }
            let binding = try ClusterNativeKeyBinding(hellos: hellos)
            for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_binding", rank: rank, nonce: peers[rank].nonce, sequence: 3, payload: binding.canonicalBytes)) }
            var confirmations: [Data] = []
            for rank in 0..<2 { confirmations.append(try #require(Data(base64Encoded: try await peers[rank].wait("native_pair_confirmation").payload))) }
            #expect(confirmations.allSatisfy { $0.count == 32 } && confirmations[0] != confirmations[1])
            for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_peer_confirmation", rank: rank, nonce: peers[rank].nonce, sequence: 4, payload: confirmations[1 - rank])) }
            for rank in 0..<2 {
                let release = try await peers[rank].wait("native_pair_owner_released")
                var expected = Data([68, 66, 78, 82, 1]); expected.append(contentsOf: SHA256.hash(data: fixture.starts[rank].canonicalBytes)); expected.append(contentsOf: [1, 1, 1])
                #expect(Data(base64Encoded: release.payload) == expected)
                try fixture.requireRetired(rank, confirmed: true)
                let frames = peers[rank].mock.snapshot().nativePairs
                #expect(frames.map(\.type) == ["native_pair_prepared", "native_pair_hello", "native_pair_confirmation", "native_pair_owner_released"])
                #expect(frames.map(\.sequence) == [1, 2, 3, 4])
                for frame in frames { try peers[rank].signer.verify(frame) }
                let body = try Data(contentsOf: fixture.directories[rank].appendingPathComponent("native-public.json"))
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(object["transcriptSHA256"] as? String == binding.transcriptSHA256.hex)
                #expect(peers[rank].mock.snapshot().inferenceChunks.isEmpty)
            }
            // Same connection, new sequence, old epoch: never permit reuse.
            try await peers[0].mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peers[0].nonce, sequence: 5))
            try await waitUntil { !peers[0].context.isLive }
            #expect(peers[0].mock.snapshot().nativePairs.count == 4)
            for peer in peers { await peer.close() }
        } catch { for peer in peers { await peer.close() }; throw error }
    }

    @Test func committedCancellationWaitsForActualNativeExitAndOwnerLeaseRelease() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_hello") // Actual PID-owned child exists and waits for its peer.
            #expect(peer.mock.snapshot().nativePairs.allSatisfy { $0.type != "native_pair_owner_released" })
            try await peer.mock.pushNativePair(fixture.message("native_pair_cancel", rank: 0, nonce: peer.nonce, sequence: 5, payload: Data([68, 66, 78, 67, 1])))
            _ = try await peer.wait("native_pair_owner_released")
            try fixture.requireRetired(0, confirmed: false)
            #expect(peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared", "native_pair_hello", "native_pair_owner_released"])
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    @Test func keyOnlyOwnerRejectsActualNativeReadyInsteadOfPublishingModelCapacity() async throws {
        let fixture = try NativePairMemberFixture(behavior: "forbidden-ready"), peer = MemberFixturePeer(installation: fixture.installations[0])
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_owner_released")
            try fixture.requireRetired(0, confirmed: false)
            #expect(peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared", "native_pair_cancel", "native_pair_owner_released"])
            #expect(peer.mock.snapshot().inferenceChunks.isEmpty)
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    @Test func lostCommittedConnectionQuarantinesDespiteLocalCleanupAndRejectsReplacement() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_hello")
            peer.control.detach(peer.context)
            try await waitUntil {
                let journal = fixture.directories[0].appendingPathComponent(".darkbloom/cluster-device/native-device.lease")
                return (try? Data(contentsOf: journal).isEmpty) == true
            }
            try fixture.requireRetired(0, confirmed: false)
            #expect(peer.control.status == "quarantined")
            #expect(peer.mock.snapshot().nativePairs.allSatisfy { $0.type != "native_pair_owner_released" })
            // A new public NWConnection cannot release or replace this obligation.
            #expect(throws: NativePairMemberError.self) {
                _ = try peer.control.attach(nonce: String(repeating: "12", count: 32), connection: .init(host: "127.0.0.1", port: 9, using: .tcp))
            }
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    @Test func pendingCancellationNeverLaunchesAndFreshConnectionCannotReplayEpoch() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_cancel", rank: 0, nonce: peer.nonce, sequence: 2, payload: Data([68, 66, 78, 67, 1])))
            try await waitUntil { peer.control.status == "idle" }
            #expect(!FileManager.default.fileExists(atPath: fixture.directories[0].appendingPathComponent("native-started").path))
            #expect(peer.mock.snapshot().nativePairs.allSatisfy { $0.type != "native_pair_owner_released" })
            peer.control.detach(peer.context)
            let replacement = try peer.control.attach(nonce: String(repeating: "34", count: 32), connection: .init(host: "127.0.0.1", port: 9, using: .tcp))
            let replay = try fixture.message("native_pair_prepare", rank: 0, nonce: replacement.nonce, sequence: 1)
            #expect(throws: NativePairMemberError.self) { try peer.control.receive(replay, on: replacement,
                receivedAt: DispatchTime.now().uptimeNanoseconds, wallUnixNanoseconds: Int64(Date().timeIntervalSince1970 * 1_000_000_000)) }
            #expect(!replacement.isLive)
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    @Test func publicWebSocketRoleAckDoesNotAuthorizeNativeInvocationWithoutTLS() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        do {
            try await peer.connect(installProductionGate: true)
            #expect(await peer.client.memberRoleFailure)
            #expect(await peer.client.sessionRegistered == false)
            #expect(peer.control.status == "idle" && peer.mock.snapshot().nativePairs.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.directories[0].appendingPathComponent("native-started").path))
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    @Test func exactPreparationDeadlineRefusesDelayedStartWithoutLaunching() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        do {
            try await peer.connect()
            let done = DispatchGroup(); done.enter()
            let prepare = try fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1)
            let session = try NativePairMemberSession(installation: fixture.installations[0], connection: peer.context,
                message: prepare, receivedAt: DispatchTime.now().uptimeNanoseconds,
                wallUnixNanoseconds: Int64(Date().timeIntervalSince1970 * 1_000_000_000)) { _, _ in done.leave() }
            session.run()
            _ = try await peer.wait("native_pair_prepared")
            let start = try fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2)
            // Inject only the locally sampled receipt time, not a wire deadline.
            // This hits the exact boundary while the real prepared state exists.
            #expect(throws: NativePairMemberError.self) { try session.accept(start, receivedAt: session.prepareDeadline) }
            #expect(session.status == "prepared")
            session.cancel(notify: false)
            try await waitUntil { done.wait(timeout: .now()) == .success }
            #expect(!FileManager.default.fileExists(atPath: fixture.directories[0].appendingPathComponent("native-started").path))
            #expect(peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared"])
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
