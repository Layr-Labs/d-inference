import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// The coordinator's shared wire goldens, copied byte for byte into
/// `Fixtures/coordinator-wire/` from darkbloom-platform
/// coordinator/tests/protocol/testdata/ (feat/cluster-pairs a0e9dfde): the
/// roster registration (N18) and the grant lease renewal (S15). Their keys are
/// test keys.
private enum WireVector {
    static func object(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
            subdirectory: "Fixtures/coordinator-wire"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    /// One JSON form for comparing objects as bytes: sorted keys, no spaces.
    static func normalized(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func bytes(_ hex: String) -> Data {
        let digits = Array(hex.utf8)
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)! })
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// A software P-256 key in the attestation signer's shape (raw X||Y public key,
/// DER signatures over SHA-256 of the input), standing in for a member's
/// Secure Enclave key.
private struct SoftwareMemberSigner: AttestationSigner {
    let key: P256.Signing.PrivateKey
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
    var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }
}

@Suite("Coordinator wire vectors: roster registration and grant lease")
struct CoordinatorWireVectorTests {
    private struct Registration {
        let vector: [String: Any]
        let clusterID: String
        let keys: [[String: String]]
        let registration: [String: Any]

        init() throws {
            vector = try WireVector.object("cluster_registration_vector")
            clusterID = try #require(vector["cluster_id"] as? String)
            keys = try #require(vector["member_keys"] as? [[String: String]])
            registration = try #require(vector["registration"] as? [String: Any])
        }

        func decode(_ object: [String: Any]) throws -> ClusterMembership {
            try JSONDecoder().decode(ClusterMembership.self, from: WireVector.data(object))
        }

        func mutated(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var copy = registration; change(&copy); return copy
        }
    }

    @Test func rosterCanonicalBytesHashAndPinsAreTheVectors() throws {
        let fixture = try Registration()
        let membership = try fixture.decode(fixture.registration)
        #expect(membership.isRosterRegistration && membership.version == 3 && membership.rank == 0)
        let roster = try #require(membership.roster)
        let canonical = try roster.canonical(clusterID: fixture.clusterID)
        #expect(WireVector.hex(canonical) == fixture.vector["roster_canonical"] as? String)
        #expect(membership.rosterSHA256 == fixture.vector["roster_sha256"] as? String)
        // The unsigned canonical form a member signs is the same bytes.
        #expect(try ClusterRoster.canonical(clusterID: fixture.clusterID, generation: roster.generation,
            keys: roster.members.map { ($0.pin, $0.sePublicKey) }) == canonical)
        for key in fixture.keys {
            let scalar = WireVector.bytes(try #require(key["private_scalar"]))
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
            let point = privateKey.publicKey.x963Representation
            #expect(point.base64EncodedString() == key["se_public_key"])
            #expect(ClusterMemberPin.of(uncompressedKey: point) == key["pin"])
            // The attestation signer's 64-byte coordinates name the same pin.
            let signer = SoftwareMemberSigner(key: privateKey)
            #expect(ClusterMemberPin.of(sePublicKey: signer.publicKeyBase64) == key["pin"])
            let pin = try #require(key["pin"])
            #expect(roster.memberKey(pin) == key["se_public_key"])
            // A fresh signature by this member's key over the canonical bytes
            // verifies in its place (ECDSA signatures are randomized).
            let signature = try ClusterRoster.signature(over: canonical, signer: signer)
            let resigned = ClusterRoster(generation: roster.generation, members: roster.members.map {
                $0.pin == key["pin"] ? .init(pin: $0.pin, sePublicKey: $0.sePublicKey, signature: signature) : $0 })
            try resigned.verify(clusterID: fixture.clusterID)
        }
        #expect(ClusterMemberPin.of(sePublicKey: Data(repeating: 7, count: 65).base64EncodedString()) == nil)
        let policy = try #require(membership.plans?.first?.policySHA256)
        #expect(membership.plan(for: policy)?.members.first == membership.memberPin)
        #expect(membership.artifact(for: "fixture/cluster-model") == membership.inventory?.first?.artifactSHA256)
        #expect(membership.edges?.allSatisfy { membership.reaches($0.peerPin) } == true)
    }

    @Test func theRegistrationEncodesToTheVectorAndRidesTheMemberRegisterFrame() throws {
        let fixture = try Registration()
        let membership = try fixture.decode(fixture.registration)
        let encoded = try JSONEncoder().encode(membership)
        #expect(try WireVector.normalized(JSONSerialization.jsonObject(with: encoded))
            == WireVector.normalized(fixture.registration))
        // Built from its parts, it is the same value.
        let built = try ClusterMembership(rosterClusterID: fixture.clusterID, memberPin: try #require(membership.memberPin),
            roster: try #require(membership.roster), deviceProfile: try #require(membership.deviceProfile),
            edges: membership.edges ?? [], inventory: membership.inventory ?? [], plans: membership.plans ?? [])
        #expect(built == membership)

        let hardware = HardwareInfo(machineModel: "fixture", chipName: "Apple M3 Ultra", chipFamily: .m3, chipTier: .ultra,
            memoryGb: 256, memoryAvailableGb: 240, cpuCores: .init(total: 32, performance: 24, efficiency: 8),
            gpuCores: 80, memoryBandwidthGbs: 819)
        let config = CoordinatorClientConfig(url: "wss://coordinator.invalid/ws", hardware: hardware,
            models: [.init(id: "fixture/cluster-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
            backendName: "mlx-swift", executionRole: .clusterMember, clusterMembership: membership)
        let resume = ClusterMembership.Resume(epoch: String(repeating: "ab", count: 16), generation: 9)
        for claim in [nil, resume] {
            let frame = try CoordinatorClientCodec.encodeRegistration(from: config,
                memberRegistrationNonce: String(repeating: "0", count: 64), clusterResume: claim)
            let object = try #require(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
            var expected = fixture.registration
            if let claim { expected["resume"] = ["epoch": claim.epoch, "generation": claim.generation] as [String: Any] }
            let claimObject = try #require(object["cluster_membership"])
            #expect(try WireVector.normalized(claimObject) == WireVector.normalized(expected))
            guard case .register(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(from: frame) else {
                Issue.record("not a register frame"); return
            }
            #expect(decoded.clusterMembership == membership.resuming(claim))
        }
    }

    /// With `DARKBLOOM_WIRE_VECTOR_OUT` naming a directory, writes the member
    /// register frames this build emits (the vector's roster registration,
    /// with and without a resume claim, and a rank registration) for the
    /// coordinator's own decoder to check. Does nothing otherwise.
    @Test func exportsRegisterFramesForTheCoordinatorDecoderWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["DARKBLOOM_WIRE_VECTOR_OUT"], !directory.isEmpty else { return }
        let fixture = try Registration()
        let roster = try fixture.decode(fixture.registration)
        let rank = try ClusterMembership(clusterID: "studio-pair", rank: 1, policySHA256: String(repeating: "b", count: 64))
        let hardware = HardwareInfo(machineModel: "fixture", chipName: "Apple M3 Ultra", chipFamily: .m3, chipTier: .ultra,
            memoryGb: 256, memoryAvailableGb: 240, cpuCores: .init(total: 32, performance: 24, efficiency: 8),
            gpuCores: 80, memoryBandwidthGbs: 819)
        let resume = ClusterMembership.Resume(epoch: String(repeating: "ab", count: 16), generation: 9)
        for (name, membership, claim) in [("roster-register", roster, nil), ("roster-register-resume", roster, resume),
                                          ("rank-register", rank, nil)] as [(String, ClusterMembership, ClusterMembership.Resume?)] {
            let config = CoordinatorClientConfig(url: "wss://coordinator.invalid/ws", hardware: hardware,
                models: [.init(id: "fixture/cluster-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
                backendName: "mlx-swift", executionRole: .clusterMember, clusterMembership: membership)
            let frame = try CoordinatorClientCodec.encodeRegistration(from: config,
                memberRegistrationNonce: String(repeating: "a", count: 64), clusterResume: claim)
            try frame.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
        }
    }

    /// The coordinator's own refusal list (TestRosterRegistrationRefusals):
    /// the member cannot build or decode any of these.
    @Test func everyRegistrationTheCoordinatorRefusesIsRefusedHere() throws {
        let fixture = try Registration()
        let pins = fixture.keys.compactMap { $0["pin"] }
        func members(_ m: [String: Any]) -> [[String: Any]] { (m["roster"] as! [String: Any])["members"] as! [[String: Any]] }
        func setMembers(_ m: inout [String: Any], _ value: [[String: Any]]) {
            var roster = m["roster"] as! [String: Any]; roster["members"] = value; m["roster"] = roster
        }
        func profile(_ m: inout [String: Any], _ key: String, _ value: Any) {
            var profile = m["device_profile"] as! [String: Any]; profile[key] = value; m["device_profile"] = profile
        }
        func edges(_ m: inout [String: Any], _ change: (inout [[String: Any]]) -> Void) {
            var value = m["edges"] as! [[String: Any]]; change(&value); m["edges"] = value
        }
        func plan(_ m: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            var plans = m["plans"] as! [[String: Any]]; change(&plans[0]); m["plans"] = plans
        }
        let cases: [String: (inout [String: Any]) -> Void] = [
            "version 4": { $0["version"] = 4 },
            "a rank": { $0["rank"] = 1 },
            "a pair policy": { $0["policy_sha256"] = String(repeating: "b", count: 64) },
            "another cluster label": { $0["cluster_id"] = "studio-other" },
            "a pin outside the roster": { $0["member_pin"] = String(repeating: "c", count: 64) },
            "no roster": { $0["roster"] = nil },
            "a missing signature": { m in var v = members(m); v[2]["signature"] = ""; setMembers(&m, v) },
            "another member's signature": { m in var v = members(m); v[0]["signature"] = v[1]["signature"]; setMembers(&m, v) },
            "a roster that is not pin ordered": { m in var v = members(m); v.swapAt(0, 1); setMembers(&m, v) },
            "a pin that is not its key's": { m in var v = members(m); v[0]["se_public_key"] = v[1]["se_public_key"]; setMembers(&m, v) },
            "a roster of one": { m in setMembers(&m, Array(members(m).prefix(1))) },
            "a roster generation of zero": { m in var r = m["roster"] as! [String: Any]; r["generation"] = 0; m["roster"] = r },
            "no device profile": { $0["device_profile"] = nil },
            "more usable than physical memory": { m in
                let memory = ((m["device_profile"] as! [String: Any])["memory_bytes"] as! NSNumber).uint64Value
                profile(&m, "usable_wired_bytes", memory + 1) },
            "no usable memory": { profile(&$0, "usable_wired_bytes", 0) },
            "no GPU cores": { profile(&$0, "gpu_cores", 0) },
            "no numerics class": { profile(&$0, "numerics_class", "") },
            "an OS build with a space": { profile(&$0, "os_build", "25C 56") },
            "an edge to itself": { m in let pin = m["member_pin"]!; edges(&m) { $0[0]["peer_pin"] = pin } },
            "an edge outside the roster": { edges(&$0) { $0[0]["peer_pin"] = String(repeating: "d", count: 64) } },
            "two edges to one peer": { edges(&$0) { $0[1]["peer_pin"] = $0[0]["peer_pin"] } },
            "a Wi-Fi edge": { edges(&$0) { $0[0]["transport"] = "wifi" } },
            "a model held twice": { m in let held = m["inventory"] as! [Any]; m["inventory"] = held + held },
            "an artifact that is not a digest": { m in
                var held = m["inventory"] as! [[String: Any]]; held[0]["artifact_sha256"] = "abc"; m["inventory"] = held },
            "a plan with a zero cut": { plan(&$0) { var cuts = $0["cuts"] as! [Int]; cuts[0] = 0; $0["cuts"] = cuts } },
            "a plan with descending cuts": { plan(&$0) { $0["cuts"] = [41, 20] } },
            "a plan with too few cuts": { plan(&$0) { $0["cuts"] = Array(($0["cuts"] as! [Int]).prefix(1)) } },
            "a plan naming a member twice": { plan(&$0) { $0["members"] = [pins[0], pins[1], pins[0]] } },
            "a plan naming a stranger": { plan(&$0) { var v = $0["members"] as! [String]; v[2] = String(repeating: "e", count: 64); $0["members"] = v } },
            "a plan of one member": { plan(&$0) { $0["members"] = [pins[0]]; $0["cuts"] = [Int]() } },
            "a plan without a model": { plan(&$0) { $0["model"] = "" } },
            "two plans for one policy": { m in let plans = m["plans"] as! [Any]; m["plans"] = plans + plans },
            "a resume without an epoch": { $0["resume"] = ["generation": 1] as [String: Any] },
            "a resume of generation zero": { $0["resume"] = ["epoch": String(repeating: "ab", count: 16), "generation": 0] as [String: Any] },
        ]
        for (name, change) in cases {
            #expect(throws: (any Error).self, "\(name)") { _ = try fixture.decode(fixture.mutated(change)) }
        }
        let resumed = try fixture.decode(fixture.mutated { $0["resume"] = ["epoch": String(repeating: "ab", count: 16), "generation": 9] as [String: Any] })
        #expect(resumed.resume == .init(epoch: String(repeating: "ab", count: 16), generation: 9))

        // The rank registration stays closed to every roster field.
        let rank: [String: Any] = ["cluster_id": "studio-pair", "rank": 1, "policy_sha256": String(repeating: "b", count: 64)]
        let registration = fixture.registration
        let rankCases: [String: (inout [String: Any]) -> Void] = [
            "a member pin": { $0["member_pin"] = pins[0] },
            "a roster": { $0["roster"] = registration["roster"] },
            "plans": { $0["plans"] = registration["plans"] },
            "version 2 with a third rank": { $0["version"] = 2; $0["rank"] = 2 },
            "a resume without a generation": { $0["resume"] = ["epoch": String(repeating: "ab", count: 16)] as [String: Any] },
        ]
        for (name, change) in rankCases {
            var value = rank; change(&value)
            #expect(throws: (any Error).self, "rank registration with \(name)") { _ = try fixture.decode(value) }
        }
        var explicit = rank; explicit["version"] = 2
        #expect(try fixture.decode(explicit).version == 2)
        var rankResumed = rank; rankResumed["resume"] = ["epoch": String(repeating: "ab", count: 16), "generation": 9] as [String: Any]
        #expect(try fixture.decode(rankResumed).resume?.generation == 9)

        // A well-formed signature over the same roster by another member's key.
        let scalar = WireVector.bytes(try #require(fixture.keys[0]["private_scalar"]))
        let canonical = WireVector.bytes(try #require(fixture.vector["roster_canonical"] as? String))
        let forged = try P256.Signing.PrivateKey(rawRepresentation: scalar).signature(for: canonical).derRepresentation
        #expect(throws: ClusterRosterError.invalidRoster) {
            _ = try fixture.decode(fixture.mutated { m in var v = members(m); v[2]["signature"] = forged.base64EncodedString(); setMembers(&m, v) })
        }
    }

    @Test func leaseRenewalPayloadsAndFrameAreTheVectors() throws {
        let vector = try WireVector.object("native_pair_lease_vector")
        let payloads = try #require(vector["payloads"] as? [[String: Any]])
        #expect(payloads.count == 3)
        for entry in payloads {
            let renewal = try #require((entry["renewal"] as? NSNumber)?.uint64Value)
            let expiry = try #require((entry["expires_at_unix_nano"] as? NSNumber)?.int64Value)
            let lease = try #require(NativePairLeaseRenewal(renewal: renewal, expiresAtUnixNano: expiry))
            #expect(WireVector.hex(lease.payload) == entry["payload_hex"] as? String)
            #expect(lease.payload.base64EncodedString() == entry["payload_base64"] as? String)
            #expect(NativePairLeaseRenewal(payload: lease.payload) == lease)
        }
        for refused in try #require(vector["refused_payload_hex"] as? [String]) {
            #expect(NativePairLeaseRenewal(payload: WireVector.bytes(refused)) == nil, "\(refused)")
        }
        let frame = try NativePairMessage.decodePublicFrame(WireVector.data(try #require(vector["frame"])))
        #expect(frame.type == "native_pair_lease" && NativePairMessage.outboundTypes.contains(frame.type)
            && !NativePairMessage.inboundTypes.contains(frame.type))
        let framePayload = try #require(Data(base64Encoded: frame.payload))
        let lease = try #require(NativePairLeaseRenewal(payload: framePayload))
        #expect(lease.expiresAtUnixNano == frame.expiresAtUnixNano && lease.renewal == 1)
    }
}
