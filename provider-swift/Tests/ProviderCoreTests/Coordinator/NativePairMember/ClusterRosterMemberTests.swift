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

    /// The same model and terms as `approval()`, pinned to no build (a model approval).
    static func modelApproval() -> ClusterRuntimeApproval {
        let pinned = approval()
        return ClusterRuntimeApproval(id: "devnet/qwen35-9b/s1", model: pinned.model, generation: pinned.generation,
            placementPolicySHA256: nil, artifactSHA256: pinned.artifactSHA256, nativeRuntimeSHA256: nil, metallibSHA256: nil,
            resourceLibrarySHA256: nil, capabilitySHA256: nil, resourcePolicySHA256: nil, profileSHA256: nil,
            schedule: pinned.schedule, maximumTransportFrame: pinned.maximumTransportFrame, maximumPlaintext: pinned.maximumPlaintext,
            maximumRecords: pinned.maximumRecords, maximumCumulativePlaintext: pinned.maximumCumulativePlaintext,
            allowedNumericsClasses: classes, minimumMembers: 2, maximumMembers: 2,
            minimumMemberUsableBytes: pinned.minimumMemberUsableBytes, notAfter: pinned.notAfter)
    }

    private func registration(_ roster: ClusterRoster, pins: [String], rank: Int, profile: ClusterRegisteredDeviceProfile,
                              mode: ClusterGenerationMode = .pipeline, tensorShares: [Int]? = nil,
                              policyBytes: Data? = nil, runtime: ClusterPlan.Runtime? = nil) throws -> NativePairMemberRoster {
        try NativePairMemberRoster(clusterID: "pub-pair", rank: rank, roster: roster, rankPins: pins,
            policyBytes: try policyBytes ?? Self.approval().canonicalPolicy(), model: "mlx-community/Qwen3.5-9B",
            artifactSHA256: String(repeating: "02", count: 32), planSHA256: String(repeating: "ab", count: 32),
            cut: 16, mode: mode, tensorShares: tensorShares, deviceProfile: profile,
            edges: [ClusterEdge(peerPin: pins[1 - rank], transport: "rdma", measuredMbps: 80_000, measuredRTTMicros: 20)],
            runtime: runtime)
    }

    /// The runtime block a member's own setup gives (its worker pin, capability, resource policy and profile).
    static func block(worker: String, capability: String = String(repeating: "06", count: 32)) -> ClusterPlan.Runtime {
        .init(nativeRuntimeSHA256: worker, capabilitySHA256: capability,
              resourcePolicySHA256: String(repeating: "07", count: 32), profileSHA256: String(repeating: "08", count: 32))
    }

    /// Under a model approval each member registers its plan with its own runtime block; under a build-pinned
    /// approval the plan names none. The block is part of the plan both members must register byte for byte.
    @Test func aModelApprovalsPlanCarriesTheMembersRuntimeBlock() throws {
        let (roster, signers) = try members()
        let pins = signers.map(\.pin)
        let profile = try ClusterRegisteredDeviceProfile(chipName: "Apple M3 Ultra", numericsClass: Self.classes[0], gpuCores: 80,
            memoryBytes: 256 << 30, usableWiredBytes: 200 << 30, osBuild: "25C56")
        let policy = try Self.modelApproval().canonicalPolicy(), block = Self.block(worker: String(repeating: "03", count: 32))
        let r0 = try registration(roster, pins: pins, rank: 0, profile: profile, policyBytes: policy, runtime: block)
        let r1 = try registration(roster, pins: pins, rank: 1, profile: profile, policyBytes: policy, runtime: block)
        #expect(r0.plan.runtime == block && r0.plan.samePlacement(as: r1.plan))
        #expect(r0.plan.policySHA256 == ClusterConfigurationCodec.sha256(policy))
        let wire = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(r0.membership)) as? [String: Any])
        let plan = try #require((wire["plans"] as? [[String: Any]])?.first)
        #expect((plan["runtime"] as? [String: String]) == ["native_runtime_sha256": block.nativeRuntimeSHA256,
            "capability_sha256": block.capabilitySHA256, "resource_policy_sha256": block.resourcePolicySHA256,
            "profile_sha256": block.profileSHA256])
        #expect(try JSONDecoder().decode(ClusterMembership.self, from: JSONEncoder().encode(r0.membership)) == r0.membership)
        // Another member's runtime is another plan.
        let other = try registration(roster, pins: pins, rank: 1, profile: profile, policyBytes: policy,
                                     runtime: Self.block(worker: String(repeating: "09", count: 32)))
        #expect(!r0.plan.samePlacement(as: other.plan))
        // A block whose digest is not 64 lowercase hex characters, or is zero, is refused.
        for bad in [Self.block(worker: String(repeating: "0", count: 64)), Self.block(worker: "AB"),
                    Self.block(worker: String(repeating: "03", count: 32), capability: String(repeating: "A", count: 64))] {
            #expect(throws: ClusterRosterError.invalidPlan) {
                _ = try registration(roster, pins: pins, rank: 0, profile: profile, policyBytes: policy, runtime: bad)
            }
        }
        // A build-pinned approval's plan carries no block, and its wire form names none.
        let pinned = try registration(roster, pins: pins, rank: 0, profile: profile)
        #expect(pinned.plan.runtime == nil)
        let pinnedWire = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(pinned.membership)) as? [String: Any])
        #expect((pinnedWire["plans"] as? [[String: Any]])?.first?["runtime"] == nil)
    }

    /// A member under a model approval: its installation takes the runtime from its own plan block and the digests it
    /// took of its own files, a start must carry exactly that runtime, and its files must hash to it.
    @Test func aMemberStartsUnderAModelApprovalOnlyWithItsOwnRuntime() throws {
        let (roster, signers) = try members()
        let pins = signers.map(\.pin)
        let root = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, _ text: String, mode: Int) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }
        func sha256(_ url: URL) throws -> String { memberHex(Data(SHA256.hash(data: try Data(contentsOf: url)))) }
        let owner = try file("owner", "model-approval-owner", mode: 0o700), worker = try file("worker", "model-approval-worker", mode: 0o700)
        let metallib = try file("mlx.metallib", "model-approval-metallib", mode: 0o600)
        let resource = try file("pagedattention.metal", "model-approval-resource", mode: 0o600)
        let gate = root.appendingPathComponent(".darkbloom/cluster-device")
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = try ClusterRegisteredDeviceProfile(chipName: "Apple M3 Ultra", numericsClass: Self.classes[0], gpuCores: 80,
            memoryBytes: 256 << 30, usableWiredBytes: 200 << 30, osBuild: "25C56")
        let policy = try Self.modelApproval().canonicalPolicy(), block = Self.block(worker: try sha256(worker))
        let files = (metallib: try sha256(metallib), resourceLibrary: try sha256(resource))
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "fixture-model",
            artifactSHA256: String(repeating: "02", count: 32), configurationSHA256: memberHex(memberDigest("fixture-config")),
            peers: (0..<2).map { ClusterWorkerPeer(id: "peer-\($0)", buildSHA256: block.nativeRuntimeSHA256) })
        let workerProfile = ClusterWorkerProfile(id: "fixture-profile", vocabularySize: 1000,
            maximumPromptTokens: 128, maximumOutputTokens: 128, maximumChunkTokens: 64, maximumContextTokens: 512)
        func installation(_ policy: Data, _ runtime: ClusterPlan.Runtime?,
                          _ digests: (metallib: String, resourceLibrary: String)?) throws -> NativePairMemberInstallation {
            try NativePairMemberInstallation(expectedCoordinatorPolicy: policy, rank: 0, clusterID: "pub-pair",
                identity: identity, profile: workerProfile, installedOwner: owner, ownerSHA256: try sha256(owner),
                nativeExecutable: worker, metallib: metallib, resourceLibrary: resource, chip: "Apple M3 Ultra",
                leaseDirectory: gate, roster: try registration(roster, pins: pins, rank: 0, profile: profile, policyBytes: policy,
                                                               runtime: runtime),
                installedDigests: digests)
        }
        let member = try installation(policy, block, files)
        #expect(member.policy.runtime == nil && member.runtime.block == block)
        #expect(memberHex(member.runtime.metallib) == files.metallib && memberHex(member.runtime.resourceLibrary) == files.resourceLibrary)
        func start(_ change: (inout [Data]) -> Void = { _ in }) throws -> ClusterNativeAuthorizationStart {
            // Worker, capability, resource policy and profile, as the coordinator copies them from the agreed plan.
            var runtime = try [block.nativeRuntimeSHA256, block.capabilitySHA256, block.resourcePolicySHA256,
                               block.profileSHA256].map { try #require(NativePairMemberPolicy.digest(hex: $0)) }
            change(&runtime)
            let common = try ClusterNativeAuthorizationCommon(epoch: UUID(), membershipGeneration: 7, nativePolicyGeneration: 3,
                membershipTranscriptSHA256: memberDigest("model-approval-membership"),
                approvedNativeBindingSHA256: Data(SHA256.hash(data: policy)), planSHA256: try #require(member.roster).planDigest,
                artifactSHA256: Data(repeating: 2, count: 32), nativeRuntimeSHA256: runtime[0], capabilitySHA256: runtime[1],
                resourcePolicySHA256: runtime[2], profileSHA256: runtime[3], schedule: .serial, maximumTransportFrameBytes: 1_048_616,
                limits: .init(maximumPlaintextBytes: 1_048_576, maximumRecordsPerDirection: 1_048_576,
                              maximumCumulativePlaintextBytesPerDirection: 4_294_967_296))
            return try .init(common: common, rank: 0, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
        }
        // Its own runtime: admitted, and its files hash to it.
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        #expect(try member.prepare(start: try start(), deadline: deadline).count == 4)
        // Any one runtime digest that is not its own is refused.
        for index in 0..<4 {
            let other = try start { $0[index] = memberDigest("another-runtime-\(index)") }
            #expect(throws: NativePairMemberError.binding, "runtime digest \(index)") { try member.requireStart(other) }
        }
        // A file that differs from the digest it took is refused at prepare.
        let changed = try installation(policy, block, (metallib: memberHex(memberDigest("another-metallib")), resourceLibrary: files.resourceLibrary))
        #expect(throws: ClusterConfigurationError.self) { _ = try changed.prepare(start: try start(), deadline: deadline) }
        // A model approval needs the plan's block and the member's own file digests; a build-pinned one refuses a block.
        #expect(throws: NativePairMemberError.binding) { _ = try installation(policy, nil, files) }
        #expect(throws: NativePairMemberError.binding) { _ = try installation(policy, block, nil) }
        #expect(throws: NativePairMemberError.binding) {
            _ = try installation(policy, block, (metallib: "AB", resourceLibrary: files.resourceLibrary))
        }
        // A block whose worker is not the setup's pin (the identity's build) is refused.
        #expect(throws: NativePairMemberError.binding) {
            _ = try installation(policy, Self.block(worker: String(repeating: "09", count: 32)), files)
        }
        #expect(throws: NativePairMemberError.binding) { _ = try installation(try Self.approval().canonicalPolicy(), block, files) }
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

    /// A tensor-parallel placement names no cut (`protocol.ClusterPlanModeCutCount`): every member holds a share of
    /// every layer. A member that named the stage end as a cut would refuse its own plan, and the pair would serve
    /// only its local API.
    @Test func aTensorParallelPlanRegistersWithoutACut() throws {
        let (roster, signers) = try members()
        let pins = signers.map(\.pin)
        let profiles = try Self.classes.map {
            try ClusterRegisteredDeviceProfile(chipName: "Apple M5 Ultra", numericsClass: $0, gpuCores: 80,
                memoryBytes: 256 << 30, usableWiredBytes: 240 << 30, osBuild: "26A434")
        }
        let r0 = try registration(roster, pins: pins, rank: 0, profile: profiles[0], mode: .tensorParallel)
        let r1 = try registration(roster, pins: pins, rank: 1, profile: profiles[1], mode: .tensorParallel)
        #expect(r0.plan.samePlacement(as: r1.plan))
        #expect(r0.plan.members == pins && r0.plan.cuts.isEmpty && r0.plan.mode == "tensor_parallel_v1")
        let wire = try #require(String(data: JSONEncoder().encode(r1.membership), encoding: .utf8))
        #expect(wire.contains(#""cuts":[]"#) && wire.contains(#""mode":"tensor_parallel_v1""#))
        #expect(try JSONDecoder().decode(ClusterMembership.self, from: Data(wire.utf8)) == r1.membership)
        // Unequal shares need the plan's tensor_parallel_shares, which this registration does not carry yet.
        #expect(throws: ClusterRosterError.invalidPlan) {
            _ = try registration(roster, pins: pins, rank: 0, profile: profiles[0], mode: .tensorParallel, tensorShares: [1, 3])
        }
    }

    @Test func aPlanNamesExactlyTheCutsOfItsMode() throws {
        let (roster, signers) = try members()
        let pins = signers.map(\.pin)
        let profile = try ClusterRegisteredDeviceProfile(chipName: "Apple M5 Ultra", numericsClass: Self.classes[0],
            gpuCores: 80, memoryBytes: 256 << 30, usableWiredBytes: 240 << 30, osBuild: "26A434")
        func membership(cuts: [UInt32], mode: String?) throws -> ClusterMembership {
            let plan = ClusterPlan(policySHA256: String(repeating: "cd", count: 32), model: "mlx-community/Qwen3.5-9B",
                planSHA256: String(repeating: "ab", count: 32), members: pins, cuts: cuts, mode: mode)
            return try ClusterMembership(rosterClusterID: "pub-pair", memberPin: pins[0], roster: roster, deviceProfile: profile,
                edges: [], inventory: [ClusterModelArtifact(model: "mlx-community/Qwen3.5-9B",
                    artifactSHA256: String(repeating: "02", count: 32))], plans: [plan])
        }
        _ = try membership(cuts: [], mode: "tensor_parallel_v1")
        _ = try membership(cuts: [16], mode: nil)
        #expect(throws: ClusterRosterError.invalidPlan) { _ = try membership(cuts: [16], mode: "tensor_parallel_v1") }
        #expect(throws: ClusterRosterError.invalidPlan) { _ = try membership(cuts: [], mode: nil) }
        // Pipeline prefill keeps its cut; the coordinator's list names the mode.
        _ = try membership(cuts: [16], mode: "pipeline_prefill_tensor_decode_v1")
        #expect(throws: ClusterRosterError.invalidPlan) { _ = try membership(cuts: [], mode: "pipeline_prefill_tensor_decode_v1") }
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
