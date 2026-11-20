import CryptoKit
import Foundation
import Testing
import DarkbloomClusterSecurity
@testable import DarkbloomClusterRemote
@testable import ProviderCore

@Suite("Owned native member mesh", .serialized)
struct NativePairMemberMeshTests {
    @Test func meshPublicVectorAndClosedBoundsMatchGo() throws {
        let digest = Data((0..<32).map(UInt8.init))
        let vector = try NativePairMesh.packet(transcript: digest, rank: 1, round: 0, value: Data([2,0,0,0]))
        #expect(vector.hex == "44424e4d01000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f010002000000")
        #expect(try NativePairMesh.keyConfirmed(digest).hex == "44424e4b01000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        for i in vector.indices {
            var changed = vector; changed[i] ^= 0x80
            #expect(throws: NativePairMessage.Invalid.self) { try NativePairMesh.decode(changed, transcript: digest, rank: 1, round: 0) }
        }
        for round in UInt8(0)..<4 {
            let value = Self.value(rank: 0, round: round)
            let reply = try NativePairMesh.packet(transcript: digest, rank: 0, round: round, value: value + value, reply: true)
            #expect(try NativePairMesh.decode(reply, transcript: digest, rank: 0, round: round, reply: true) == value + value)
            #expect(throws: NativePairMessage.Invalid.self) { try NativePairMesh.decode(reply, transcript: digest, rank: 0, round: round) }
            #expect(throws: NativePairMessage.Invalid.self) { try NativePairMesh.decode(Data(reply.dropLast()), transcript: digest, rank: 0, round: round, reply: true) }
        }
        #expect(throws: NativePairMessage.Invalid.self) { try NativePairMesh.packet(transcript: digest, rank: 2, round: 0, value: Data([2,0,0,0])) }
        #expect(throws: NativePairMessage.Invalid.self) { try NativePairMesh.packet(transcript: digest, rank: 0, round: 4, value: Data([0,0,0,0])) }
    }

    @Test func onlyCombinedOwnerProfileAdmitsExtendedPublicSequence() throws {
        let epoch = UUID(), lease = UUID(), incarnation = UUID()
        var frame = OwnerWire(kind: "bootstrapRound", epoch: epoch, lease: lease, incarnation: incarnation,
            sequence: 1, bootstrapSequence: 6, bootstrapBytes: Data([0,0,0,0]))
        #expect(throws: (any Error).self) { try frame.encoded(commandStream: false) }
        frame.bootstrapProfile = .nativeKeyPreludeMesh2
        #expect(try OwnerWire.decode(frame.encoded(commandStream: false), commandStream: false).bootstrapSequence == 6)
        frame.bootstrapSequence = 7
        #expect(throws: (any Error).self) { try frame.encoded(commandStream: false) }
        frame.bootstrapSequence = 3; frame.bootstrapProfile = .mesh2
        #expect(throws: (any Error).self) { try frame.encoded(commandStream: false) }
        frame.bootstrapProfile = nil
        let legacy = try frame.encoded(commandStream: false)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("bootstrapProfile"))
        #expect(throws: (any Error).self) { try ClusterOwnerBootstrapProfile.nativeKeyPrelude.validate(sequence: 3, contribution: Data([0,0,0,0])) }
        try ClusterOwnerBootstrapProfile.nativeKeyPreludeMesh2.validate(sequence: 6, contribution: Data([0,0,0,0]))
    }

    @Test func actualMeshFourRoundsUseAuthenticatedSocketAndRetireWithoutReady() async throws {
        let fixture = try NativePairMemberFixture(behavior: "mesh")
        let peers = fixture.installations.map(MemberFixturePeer.init)
        do {
            let binding = try await confirmed(fixture, peers)
            for peer in peers { #expect(peer.mock.snapshot().nativePairs.allSatisfy { $0.type != "native_pair_mesh" }) }
            try await ready(fixture, peers, binding)
            for round in UInt8(0)..<4 {
                var values: [Data] = []
                for rank in 0..<2 { values.append(try await contribution(peers[rank], binding, rank: rank, round: round)) }
                #expect(values == [Self.value(rank: 0, round: round), Self.value(rank: 1, round: round)])
                for rank in 0..<2 {
                    let payload = try NativePairMesh.packet(transcript: binding.transcriptSHA256, rank: rank, round: round, value: values[0] + values[1], reply: true)
                    try await peers[rank].mock.pushNativePair(fixture.message("native_pair_mesh_reply", rank: rank, nonce: peers[rank].nonce, sequence: UInt64(round) + 6, payload: payload))
                }
            }
            for rank in 0..<2 {
                let release = try await peers[rank].wait("native_pair_owner_released")
                var expected = Data([68,66,78,82,1]); expected.append(contentsOf: SHA256.hash(data: fixture.starts[rank].canonicalBytes)); expected.append(contentsOf: [1,1,1])
                #expect(Data(base64Encoded: release.payload) == expected)
                try fixture.requireRetired(rank, confirmed: true)
                let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directories[rank].appendingPathComponent("native-mesh.json"))) as? [String: Any])
                #expect(object["rounds"] as? Int == 4 && object["replyBytes"] as? [Int] == [8,128,8,8])
                #expect(object["sameAuthenticatedSocket"] as? Bool == true && object["modelReadyPublished"] as? Bool == false)
                let frames = peers[rank].mock.snapshot().nativePairs
                #expect(frames.map(\.type) == ["native_pair_prepared", "native_pair_hello", "native_pair_confirmation", "native_pair_key_confirmed"] + Array(repeating: "native_pair_mesh", count: 4) + ["native_pair_owner_released"])
                #expect(frames.map(\.sequence) == Array(UInt64(1)...9))
                for frame in frames { try peers[rank].signer.verify(frame) }
                #expect(peers[rank].mock.snapshot().inferenceChunks.isEmpty)
            }
            for peer in peers { await peer.close() }
        } catch { for peer in peers { await peer.close() }; throw error }
    }

    @Test func meshCancellationJoinsActualNativeOwnersAtPendingRound() async throws {
        let fixture = try NativePairMemberFixture(behavior: "mesh"), peers = fixture.installations.map(MemberFixturePeer.init)
        do {
            let binding = try await confirmed(fixture, peers)
            try await ready(fixture, peers, binding)
            for rank in 0..<2 { _ = try await contribution(peers[rank], binding, rank: rank, round: 0) }
            for rank in 0..<2 {
                #expect(!FileManager.default.fileExists(atPath: fixture.directories[rank].appendingPathComponent("native-mesh.json").path))
                try await peers[rank].mock.pushNativePair(fixture.message("native_pair_cancel", rank: rank, nonce: peers[rank].nonce, sequence: 6, payload: Data([68,66,78,67,1])))
            }
            for rank in 0..<2 { _ = try await peers[rank].wait("native_pair_owner_released"); try fixture.requireRetired(rank, confirmed: true) }
            for peer in peers { await peer.close() }
        } catch { for peer in peers { await peer.close() }; throw error }
    }

    @Test func meshWrongLocalEchoClosesControlAndNeverReturnsCapacity() async throws {
        let fixture = try NativePairMemberFixture(behavior: "mesh"), peers = fixture.installations.map(MemberFixturePeer.init)
        do {
            let binding = try await confirmed(fixture, peers); try await ready(fixture, peers, binding)
            for round in UInt8(0)..<2 {
                for rank in 0..<2 { _ = try await contribution(peers[rank], binding, rank: rank, round: round) }
                let value = round == 0 ? Self.value(rank: 0, round: 0) + Self.value(rank: 1, round: 0) : Data(repeating: 99, count: 128)
                for rank in 0..<2 {
                    let packet = try NativePairMesh.packet(transcript: binding.transcriptSHA256, rank: rank, round: round, value: value, reply: true)
                    try await peers[rank].mock.pushNativePair(fixture.message("native_pair_mesh_reply", rank: rank, nonce: peers[rank].nonce, sequence: UInt64(round)+6, payload: packet))
                }
            }
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < end && peers.contains(where: { $0.context.isLive }) { try await Task.sleep(for: .milliseconds(5)) }
            for peer in peers { #expect(!peer.context.isLive); await peer.close() }
            // Disconnect cannot publish the signed old-connection release. The
            // local obligation remains quarantined even after actual cleanup.
            let cleanup = ContinuousClock.now.advanced(by: .seconds(5))
            for rank in 0..<2 {
                let journal = fixture.directories[rank].appendingPathComponent(".darkbloom/cluster-device/native-device.lease")
                while ContinuousClock.now < cleanup {
                    if try Data(contentsOf: journal).isEmpty { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                try fixture.requireRetired(rank, confirmed: true)
                #expect(peers[rank].control.status == "quarantined")
                #expect(peers[rank].mock.snapshot().nativePairs.allSatisfy { $0.type != "native_pair_owner_released" })
                #expect(!FileManager.default.fileExists(atPath: fixture.directories[rank].appendingPathComponent("native-mesh.json").path))
            }
        } catch { for peer in peers { await peer.close() }; throw error }
    }

    @Test func combinedMeshOwnerStillRefusesNativeReady() async throws {
        let fixture = try NativePairMemberFixture(behavior: "mesh-forbidden-ready"), peer = MemberFixturePeer(installation: fixture.installations[0])
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_owner_released"); try fixture.requireRetired(0, confirmed: false)
            #expect(peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared", "native_pair_cancel", "native_pair_owner_released"])
            #expect(peer.mock.snapshot().inferenceChunks.isEmpty)
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    private static func value(rank: Int, round: UInt8) -> Data {
        if round == 0 { return Data([2,0,0,0]) }
        if round == 1 { return Data(repeating: UInt8(rank + 20), count: 64) }
        return Data([0,0,0,0])
    }
    private func confirmed(_ fixture: NativePairMemberFixture, _ peers: [MemberFixturePeer]) async throws -> ClusterNativeKeyBinding {
        for peer in peers { try await peer.connect() }
        for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_prepare", rank: rank, nonce: peers[rank].nonce, sequence: 1)) }
        for rank in 0..<2 { _ = try await peers[rank].wait("native_pair_prepared") }
        for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_owner_start", rank: rank, nonce: peers[rank].nonce, sequence: 2)) }
        var hellos: [ClusterNativeKeyHello] = []
        for peer in peers { hellos.append(try ClusterNativeKeyHello(encoded: #require(Data(base64Encoded: try await peer.wait("native_pair_hello").payload)))) }
        let binding = try ClusterNativeKeyBinding(hellos: hellos)
        for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_binding", rank: rank, nonce: peers[rank].nonce, sequence: 3, payload: binding.canonicalBytes)) }
        var tags: [Data] = []
        for peer in peers { tags.append(try #require(Data(base64Encoded: try await peer.wait("native_pair_confirmation").payload))) }
        for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_peer_confirmation", rank: rank, nonce: peers[rank].nonce, sequence: 4, payload: tags[1-rank])) }
        for peer in peers {
            let message = try await peer.wait("native_pair_key_confirmed")
            #expect(try Data(base64Encoded: message.payload) == NativePairMesh.keyConfirmed(binding.transcriptSHA256))
        }
        return binding
    }
    private func ready(_ fixture: NativePairMemberFixture, _ peers: [MemberFixturePeer], _ binding: ClusterNativeKeyBinding) async throws {
        for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_mesh_ready", rank: rank, nonce: peers[rank].nonce, sequence: 5, payload: NativePairMesh.keyConfirmed(binding.transcriptSHA256))) }
    }
    private func contribution(_ peer: MemberFixturePeer, _ binding: ClusterNativeKeyBinding, rank: Int, round: UInt8) async throws -> Data {
        let snapshot = try #require(try await peer.mock.waitForSnapshot(timeout: .seconds(5)) { $0.nativePairs.filter { $0.type == "native_pair_mesh" }.count > Int(round) })
        let frame = snapshot.nativePairs.filter { $0.type == "native_pair_mesh" }[Int(round)]
        try peer.signer.verify(frame)
        return try NativePairMesh.decode(#require(Data(base64Encoded: frame.payload)), transcript: binding.transcriptSHA256, rank: rank, round: round)
    }
}
