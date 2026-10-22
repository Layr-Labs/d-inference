import CryptoKit
import Darwin
import Foundation
import Metal
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// The roster registration (cluster_membership v3) of a member whose saved
/// setup carries a cluster approval and the roster both members
/// countersigned: its pin, the roster, its device profile, its confirmed
/// links, the model it holds and the plan it derived for the approval. The
/// coordinator forms a cluster only from members that registered byte-equal
/// rosters and byte-equal plans, so both members derive the plan from their
/// own saved setups (the same selected partition, the same rank order).
public struct NativePairMemberRoster: Sendable, Equatable {
    /// What this member registers.
    public let membership: ClusterMembership
    /// This member's pin (SHA-256 of its Secure Enclave key).
    public let memberPin: String
    /// The other member's Secure Enclave key (X9.63, 65 bytes): the pin its
    /// worker's data-plane hello must be certified under.
    public let peerIdentity: Data
    /// The plan this member derived and registered: the start of a session
    /// formed under the approval must name exactly its digest.
    public let plan: ClusterPlan

    /// `rankPins`: the roster pins in the setup's rank order. `cut`: the
    /// selected partition's first stage end (the planner's cut).
    public init(clusterID: String, rank: Int, roster: ClusterRoster, rankPins: [String], policyBytes: Data,
                model: String, artifactSHA256: String, planSHA256: String, cut: Int, mode: ClusterGenerationMode,
                deviceProfile: ClusterRegisteredDeviceProfile, edges: [ClusterEdge]) throws {
        guard rankPins.count == 2, (0...1).contains(rank), cut > 0,
              let key = roster.memberKey(rankPins[1 - rank]), let peer = Data(base64Encoded: key), peer.count == 65 else {
            throw ClusterRosterError.invalidMembership
        }
        let policy = Data(SHA256.hash(data: policyBytes)).map { String(format: "%02x", $0) }.joined()
        plan = ClusterPlan(policySHA256: policy, model: model, planSHA256: planSHA256, members: rankPins,
            cuts: [UInt32(cut)], mode: mode == .pipeline ? nil : mode.rawValue)
        membership = try ClusterMembership(rosterClusterID: clusterID, memberPin: rankPins[rank], roster: roster,
            deviceProfile: deviceProfile, edges: edges,
            inventory: [ClusterModelArtifact(model: model, artifactSHA256: artifactSHA256)], plans: [plan])
        memberPin = rankPins[rank]; peerIdentity = peer
    }

    /// The plan digest as the start carries it.
    var planDigest: Data {
        let digits = Array(plan.planSHA256.utf8).map { $0 < 58 ? $0 - 48 : $0 - 87 }
        return Data(stride(from: 0, to: 64, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
    }

    /// This rank's data-plane credential line for one committed start (S16):
    /// a fresh worker key certified by this member's Secure Enclave key, this
    /// member's identity, and the peer member's roster key as the pin its
    /// worker's hello must verify under. Only the worker's control pipe sees it.
    func dataPlaneTrust(start: ClusterNativeAuthorizationStart, signer: any AttestationSigner) throws -> Data {
        try dataPlaneTrust(epoch: start.common.epoch, rank: start.rank, signer: signer)
    }

    func dataPlaneTrust(epoch: UUID, rank: Int, signer: any AttestationSigner) throws -> Data {
        guard let raw = Data(base64Encoded: signer.publicKeyBase64), raw.count == 64,
              ClusterMemberPin.of(uncompressedKey: Data([4]) + raw) == memberPin else {
            throw ClusterRosterError.invalidMembership
        }
        let worker = P256.Signing.PrivateKey()
        let message = try ClusterDataPlaneCertificate.message(epoch: epoch, rank: rank,
            workerSigningPublicKey: worker.publicKey.x963Representation)
        let certificate = try P256.Signing.ECDSASignature(derRepresentation: signer.sign(message)).rawRepresentation
        let credential = try ClusterDataPlaneCredential(epoch: epoch, rank: rank, workerSigningKey: worker.rawRepresentation,
            workerCertificate: certificate, memberIdentity: Data([4]) + raw, peerPin: peerIdentity)
        let fields = credential.wireFields
        return try ClusterWorkerCodec.encode(ClusterWorkerDataPlaneTrust(membershipEpoch: epoch, rank: rank,
            workerSigningKey: fields.workerSigningKey, workerCertificate: fields.workerCertificate,
            memberIdentity: fields.memberIdentity, peerPin: fields.peerPin))
    }
}

/// This Mac's device profile v2 as a member registers it.
public enum ClusterMemberDeviceProfile {
    /// The numerics class: GPU architecture generation, whether the neural
    /// accelerator path (NAX) is on, the MLX metallib, and macOS major.minor
    /// (PROD-PLAN-NMAC 2.7). Members of one class give exactly equal results
    /// for one artifact and runtime; the approval lists the classes it admits.
    public static func numericsClass(architecture: String, metallibSHA256: String,
                                     os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        let name = architecture.hasPrefix("applegpu_") ? String(architecture.dropFirst(9)) : architecture
        let digits = name.dropFirst().prefix { $0.isNumber }
        let generation = Int(digits) ?? 0
        let variant = name.dropFirst(1 + digits.count).first
        // NAX is on from generation 17, or 18 for 'p' parts.
        let nax = generation >= 18 || (generation >= 17 && variant != "p")
        return "\(name)-nax\(nax ? 1 : 0)-mlx-\(metallibSHA256.prefix(8))-macos\(os.majorVersion).\(os.minorVersion)"
    }

    /// From the hardware report, Metal's architecture name and recommended
    /// working set (the wired limit a worker may use), and the OS build.
    public static func current(chipName: String, gpuCores: UInt32, metallibSHA256: String) throws -> ClusterRegisteredDeviceProfile {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ClusterRosterError.invalidProfile }
        let memory = ProcessInfo.processInfo.physicalMemory
        let usable = min(memory, device.recommendedMaxWorkingSetSize)
        return try ClusterRegisteredDeviceProfile(chipName: chipName,
            numericsClass: numericsClass(architecture: device.architecture.name, metallibSHA256: metallibSHA256),
            gpuCores: gpuCores, memoryBytes: memory, usableWiredBytes: usable, osBuild: osBuild())
    }

    static func osBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}
