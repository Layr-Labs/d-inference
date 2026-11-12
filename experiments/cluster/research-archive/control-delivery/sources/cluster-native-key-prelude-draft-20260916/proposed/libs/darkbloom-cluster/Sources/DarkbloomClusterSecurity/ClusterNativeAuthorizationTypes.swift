import Foundation

/// Closed public metadata. These values do not approve a runtime, attest a
/// process, authorize launch or permit constructing a traffic key by themselves.
public enum ClusterNativeKeyError: Error, Equatable, Sendable {
    case invalidBinding, invalidKey, wrongContext, authenticationFailed
    case inactive, concurrentOperation, deadline, alreadyConsumed
}
public enum ClusterNativePrefillSchedule: UInt8, Sendable { case serial = 1, oneChunkLookahead = 2 }

public struct ClusterNativeAuthorizationCommon: Sendable {
    public let epoch: UUID
    public let membershipGeneration: UInt64
    public let nativePolicyGeneration: UInt64
    public let membershipTranscriptSHA256: Data
    public let approvedNativeBindingSHA256: Data
    public let planSHA256: Data
    public let artifactSHA256: Data
    public let nativeRuntimeSHA256: Data
    public let capabilitySHA256: Data
    public let resourcePolicySHA256: Data
    public let profileSHA256: Data
    public let schedule: ClusterNativePrefillSchedule
    public let maximumTransportFrameBytes: Int
    public let limits: ClusterRecordLimits

    public init(epoch: UUID, membershipGeneration: UInt64, nativePolicyGeneration: UInt64,
                membershipTranscriptSHA256: Data, approvedNativeBindingSHA256: Data,
                planSHA256: Data, artifactSHA256: Data, nativeRuntimeSHA256: Data,
                capabilitySHA256: Data, resourcePolicySHA256: Data, profileSHA256: Data,
                schedule: ClusterNativePrefillSchedule, maximumTransportFrameBytes: Int,
                limits: ClusterRecordLimits) throws {
        let digests = [membershipTranscriptSHA256, approvedNativeBindingSHA256, planSHA256,
            artifactSHA256, nativeRuntimeSHA256, capabilitySHA256, resourcePolicySHA256, profileSHA256]
        guard !clusterRecordUUIDBytes(epoch).allSatisfy({ $0 == 0 }), membershipGeneration > 0,
              nativePolicyGeneration > 0, digests.allSatisfy({ $0.count == 32 && !$0.allSatisfy({ $0 == 0 }) }),
              maximumTransportFrameBytes >= limits.maximumPlaintextBytes + 40,
              maximumTransportFrameBytes <= ClusterRecordLimits.hardMaximumPlaintextBytes + 40 else {
            throw ClusterNativeKeyError.invalidBinding
        }
        self.epoch = epoch; self.membershipGeneration = membershipGeneration
        self.nativePolicyGeneration = nativePolicyGeneration
        self.membershipTranscriptSHA256 = membershipTranscriptSHA256
        self.approvedNativeBindingSHA256 = approvedNativeBindingSHA256
        self.planSHA256 = planSHA256; self.artifactSHA256 = artifactSHA256
        self.nativeRuntimeSHA256 = nativeRuntimeSHA256; self.capabilitySHA256 = capabilitySHA256
        self.resourcePolicySHA256 = resourcePolicySHA256; self.profileSHA256 = profileSHA256
        self.schedule = schedule; self.maximumTransportFrameBytes = maximumTransportFrameBytes; self.limits = limits
    }
}

public struct ClusterNativeAuthorizationStart: Sendable {
    public let common: ClusterNativeAuthorizationCommon
    public let rank: Int
    public let ownerIncarnation: UUID
    public let leaseID: UUID
    public let launchID: UUID
    public init(common: ClusterNativeAuthorizationCommon, rank: Int, ownerIncarnation: UUID,
                leaseID: UUID, launchID: UUID) throws {
        guard (0...1).contains(rank), [ownerIncarnation, leaseID, launchID].allSatisfy({
            !clusterRecordUUIDBytes($0).allSatisfy({ $0 == 0 })
        }) else { throw ClusterNativeKeyError.invalidBinding }
        self.common = common; self.rank = rank; self.ownerIncarnation = ownerIncarnation
        self.leaseID = leaseID; self.launchID = launchID
    }
}

public struct ClusterNativeKeyHello: Sendable {
    public let start: ClusterNativeAuthorizationStart
    public let publicKey: Data
    public init(start: ClusterNativeAuthorizationStart, publicKey: Data) throws {
        guard nativeCanonicalX25519PublicKey(publicKey) else { throw ClusterNativeKeyError.invalidKey }
        self.start = start; self.publicKey = publicKey
    }
}

public struct ClusterNativeKeyBinding: Sendable {
    public let hellos: [ClusterNativeKeyHello]
    public init(hellos: [ClusterNativeKeyHello]) throws {
        guard hellos.count == 2, hellos[0].start.rank == 0, hellos[1].start.rank == 1,
              hellos[0].start.common.canonicalBytes == hellos[1].start.common.canonicalBytes,
              hellos[0].publicKey != hellos[1].publicKey,
              hellos[0].start.ownerIncarnation != hellos[1].start.ownerIncarnation,
              hellos[0].start.leaseID != hellos[1].start.leaseID,
              hellos[0].start.launchID != hellos[1].start.launchID else { throw ClusterNativeKeyError.invalidBinding }
        self.hellos = hellos
    }
}

// The native CryptoKit public key has a canonical little-endian field encoding.
// Reject alternate encodings rather than let transcript identities alias them.
func nativeCanonicalX25519PublicKey(_ data: Data) -> Bool {
    guard data.count == 32, !data.allSatisfy({ $0 == 0 }) else { return false }
    let value = Array(data)
    let modulus: [UInt8] = [0xed] + Array(repeating: 0xff, count: 30) + [0x7f]
    for index in (0..<32).reversed() {
        if value[index] != modulus[index] { return value[index] < modulus[index] }
    }
    return false
}
