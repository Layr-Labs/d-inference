import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

/// The roster registration on the member side (registration v3): the cluster
/// approval's canonical policy bytes as the coordinator encodes them, the plan
/// both members derive, and the data-plane credential each member certifies
/// with its own key and pins to the other member's roster key.
@Suite("Cluster roster member")
struct ClusterRosterMemberTests {
    private struct SoftwareMemberSigner: AttestationSigner {
        let key: P256.Signing.PrivateKey
        func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
        var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }
        var pin: String { ClusterMemberPin.of(uncompressedKey: key.publicKey.x963Representation) }
        var x963: String { key.publicKey.x963Representation.base64EncodedString() }
    }

    static let classes = ["g15d-nax0-mlx-f7fb1831-macos26.2", "g17s-nax1-mlx-f7fb1831-macos26.2"]

    static func approval() -> ClusterRuntimeApproval {
        func h(_ b: UInt8) -> String { String(repeating: String(format: "%02x", b), count: 32) }
        return ClusterRuntimeApproval(id: "pub-cluster-qwen35-9b", model: "mlx-community/Qwen3.5-9B", generation: 3,
            placementPolicySHA256: h(1), artifactSHA256: h(2), nativeRuntimeSHA256: h(3), metallibSHA256: h(4),
            resourceLibrarySHA256: h(5), capabilitySHA256: h(6), resourcePolicySHA256: h(7), profileSHA256: h(8),
            schedule: 1, maximumTransportFrame: 1_048_616, maximumPlaintext: 1_048_576, maximumRecords: 1_048_576,
            maximumCumulativePlaintext: 4_294_967_296, allowedNumericsClasses: classes, minimumMembers: 2, maximumMembers: 2,
            minimumMemberUsableBytes: 64 << 30, notAfter: "2026-12-31T23:59:59Z")
    }

    /// darkbloom-platform 8b36c5c7 `canonicalClusterRuntimeApproval` of the same entry (Go, printed once).
    static let coordinatorCanonicalHex = "6461726b626c6f6f6d2f636f6f7264696e61746f722d636c75737465722d72756e74696d652d617070726f76616c2f763100000000157075622d636c75737465722d7177656e33352d3962000000186d6c782d636f6d6d756e6974792f5177656e332e352d394200000000000000030101010101010101010101010101010101010101010101010101010101010101020202020202020202020202020202020202020202020202020202020202020203030303030303030303030303030303030303030303030303030303030303030404040404040404040404040404040404040404040404040404040404040404050505050505050505050505050505050505050505050505050505050505050506060606060606060606060606060606060606060606060606060606060606060707070707070707070707070707070707070707070707070707070707070707080808080808080808080808080808080808080808080808080808080808080801010100100028001000000000000000100000000000010000000018f67c24e00236000202000000100000000000000009502f90000000001bf08eb00000000014f46b04000000000200000020673135642d6e6178302d6d6c782d66376662313833312d6d61636f7332362e3200000020673137732d6e6178312d6d6c782d66376662313833312d6d61636f7332362e32"

    @Test func clusterApprovalBytesMatchTheCoordinator() throws {
        let bytes = try Self.approval().canonicalPolicy()
        #expect(bytes.map { String(format: "%02x", $0) }.joined() == Self.coordinatorCanonicalHex)
        let policy = try NativePairMemberPolicy(bytes)
        #expect(policy.cluster?.numericsClasses == Self.classes)
        #expect(policy.cluster?.minimumMemberUsableBytes == 64 << 30)
        #expect(policy.cluster?.leaseTermsNanoseconds == [40_000_000_000, 120_000_000_000, 90_000_000_000])
        #expect(policy.chips.isEmpty && policy.model == "mlx-community/Qwen3.5-9B")
    }

    private func members() throws -> (ClusterRoster, [SoftwareMemberSigner]) {
        let signers = [SoftwareMemberSigner(key: .init()), SoftwareMemberSigner(key: .init())]
        let keys = signers.map { (pin: $0.pin, sePublicKey: $0.x963) }.sorted { $0.pin < $1.pin }
        let canonical = try ClusterRoster.canonical(clusterID: "pub-pair", generation: 1, keys: keys)
        let roster = ClusterRoster(generation: 1, members: try keys.map { key in
            let signer = signers.first { $0.pin == key.pin }!
            return .init(pin: key.pin, sePublicKey: key.sePublicKey,
                signature: try ClusterRoster.signature(over: canonical, signer: signer))
        })
        try roster.verify(clusterID: "pub-pair")
        return (roster, signers)
    }

    private func registration(_ roster: ClusterRoster, pins: [String], rank: Int, profile: ClusterRegisteredDeviceProfile) throws -> NativePairMemberRoster {
        try NativePairMemberRoster(clusterID: "pub-pair", rank: rank, roster: roster, rankPins: pins,
            policyBytes: try Self.approval().canonicalPolicy(), model: "mlx-community/Qwen3.5-9B",
            artifactSHA256: String(repeating: "02", count: 32), planSHA256: String(repeating: "ab", count: 32),
            cut: 16, mode: .pipeline, deviceProfile: profile,
            edges: [ClusterEdge(peerPin: pins[1 - rank], transport: "rdma", measuredMbps: 80_000, measuredRTTMicros: 20)])
    }

    @Test func bothMembersRegisterOneRosterAndOnePlan() throws {
        let (roster, signers) = try members()
        let pins = signers.map(\.pin)
        let p0 = try ClusterRegisteredDeviceProfile(chipName: "Apple M3 Ultra", numericsClass: Self.classes[0], gpuCores: 80,
            memoryBytes: 256 << 30, usableWiredBytes: 200 << 30, osBuild: "25C56")
        let p1 = try ClusterRegisteredDeviceProfile(chipName: "Apple M5 Max", numericsClass: Self.classes[1], gpuCores: 40,
            memoryBytes: 128 << 30, usableWiredBytes: 100 << 30, osBuild: "25C56")
        let r0 = try registration(roster, pins: pins, rank: 0, profile: p0)
        let r1 = try registration(roster, pins: pins, rank: 1, profile: p1)
        #expect(r0.plan.samePlacement(as: r1.plan))
        #expect(r0.plan.members == pins && r0.plan.cuts == [16] && r0.plan.mode == nil)
        #expect(r0.plan.policySHA256 == Data(SHA256.hash(data: try Self.approval().canonicalPolicy())).map { String(format: "%02x", $0) }.joined())
        #expect(r0.membership.rosterSHA256 != nil && r0.membership.rosterSHA256 == r1.membership.rosterSHA256)
        #expect(r0.membership.isRosterRegistration && r0.memberPin == pins[0] && r1.memberPin == pins[1])
        // The wire form decodes as a roster registration (the coordinator's own decoder checks the same in the e2e).
        let decoded = try JSONDecoder().decode(ClusterMembership.self, from: JSONEncoder().encode(r1.membership))
        #expect(decoded == r1.membership)
        // A roster that does not list this rank's pin in the setup's order is refused.
        #expect(throws: (any Error).self) { _ = try registration(roster, pins: [pins[0], pins[0]], rank: 0, profile: p0) }
    }

    @Test func eachMemberCertifiesItsWorkerAndPinsThePeer() throws {
        let (roster, signers) = try members()
        let pins = signers.map(\.pin)
        let profile = try ClusterRegisteredDeviceProfile(chipName: "Apple M3 Ultra", numericsClass: Self.classes[0], gpuCores: 80,
            memoryBytes: 256 << 30, usableWiredBytes: 200 << 30, osBuild: "25C56")
        let epoch = UUID()
        let lines = try (0...1).map { rank in
            try registration(roster, pins: pins, rank: rank, profile: profile)
                .dataPlaneTrust(epoch: epoch, rank: rank, signer: signers[rank])
        }
        let credentials = try lines.map { line -> ClusterDataPlaneCredential in
            let t = try ClusterWorkerCodec.decodeDataPlaneTrust(line)
            #expect(t.membershipEpoch == epoch)
            return try ClusterDataPlaneCredential(epoch: t.membershipEpoch, rank: t.rank, workerSigningKey: t.workerSigningKey,
                workerCertificate: t.workerCertificate, memberIdentity: t.memberIdentity, peerPin: t.peerPin)
        }
        #expect(credentials[0].peerPin.identityPublicKey == signers[1].key.publicKey.x963Representation)
        #expect(credentials[1].peerPin.identityPublicKey == signers[0].key.publicKey.x963Representation)
        // The two workers' hellos verify against each other's pins and confirm one exchange.
        let scope = Data(SHA256.hash(data: Data("pub-scope".utf8)))
        let exchanges = try credentials.map { try ClusterDataPlaneKeyExchange(credential: $0, scopeSHA256: scope) }
        let tags = try [exchanges[0].accept(peerHello: exchanges[1].hello), exchanges[1].accept(peerHello: exchanges[0].hello)]
        try exchanges[0].confirm(peerTag: tags[1]); try exchanges[1].confirm(peerTag: tags[0])
        // A signer that is not the roster's member for this rank issues nothing.
        #expect(throws: (any Error).self) {
            _ = try registration(roster, pins: pins, rank: 0, profile: profile).dataPlaneTrust(epoch: epoch, rank: 0, signer: signers[1])
        }
    }

    @Test func numericsClassFollowsTheArchitecture() {
        let os = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        #expect(ClusterMemberDeviceProfile.numericsClass(architecture: "applegpu_g15d", metallibSHA256: "f7fb1831aa", os: os)
            == "g15d-nax0-mlx-f7fb1831-macos26.2")
        #expect(ClusterMemberDeviceProfile.numericsClass(architecture: "applegpu_g17s", metallibSHA256: "f7fb1831aa", os: os)
            == "g17s-nax1-mlx-f7fb1831-macos26.2")
        #expect(ClusterMemberDeviceProfile.numericsClass(architecture: "applegpu_g17p", metallibSHA256: "f7fb1831aa", os: os)
            == "g17p-nax0-mlx-f7fb1831-macos26.2")
        // M5 Ultra (Metal reports applegpu_g17d): NAX on, and a class of its own: the M5 Max ('s')
        // and the M5 Ultra ('d') never share a qualification, nor do two macOS minor versions.
        let ultra = ClusterMemberDeviceProfile.numericsClass(architecture: "applegpu_g17d", metallibSHA256: "f7fb1831aa",
            os: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1))
        #expect(ultra == "g17d-nax1-mlx-f7fb1831-macos27.0")
        #expect(ultra != ClusterMemberDeviceProfile.numericsClass(architecture: "applegpu_g17s", metallibSHA256: "f7fb1831aa",
            os: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)))
        #expect(ultra != ClusterMemberDeviceProfile.numericsClass(architecture: "applegpu_g17d", metallibSHA256: "f7fb1831aa",
            os: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)))
    }
}
