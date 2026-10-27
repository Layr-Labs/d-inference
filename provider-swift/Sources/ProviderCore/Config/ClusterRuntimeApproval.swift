import Foundation

/// One entry of the coordinator operator's `cluster_approvals`
/// (`darkbloom_cluster_catalog_v2`), saved field for field so the member
/// derives the same canonical policy bytes the coordinator does. Mirrors
/// `clusterRuntimeApprovalFile` and `canonicalClusterRuntimeApproval`
/// (darkbloom-platform coordinator/registry/native_pair_catalog_file.go,
/// native_pair_approval.go). Saving an entry approves nothing.
public struct ClusterRuntimeApproval: Codable, Sendable, Equatable {
    public let id: String
    public let model: String
    public let generation: UInt64
    public let placementPolicySHA256: String
    public let artifactSHA256: String
    public let nativeRuntimeSHA256: String
    public let metallibSHA256: String
    public let resourceLibrarySHA256: String
    public let capabilitySHA256: String
    public let resourcePolicySHA256: String
    public let profileSHA256: String
    public let schedule: UInt8
    public let maximumTransportFrame: UInt32
    public let maximumPlaintext: UInt32
    public let maximumRecords: UInt64
    public let maximumCumulativePlaintext: UInt64
    public let allowedNumericsClasses: [String]
    public let minimumMembers: Int
    public let maximumMembers: Int
    public let minimumMemberUsableBytes: UInt64
    public let notAfter: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, model, generation, schedule
        case placementPolicySHA256 = "placement_policy_sha256"
        case artifactSHA256 = "artifact_sha256"
        case nativeRuntimeSHA256 = "native_runtime_sha256"
        case metallibSHA256 = "metallib_sha256"
        case resourceLibrarySHA256 = "resource_library_sha256"
        case capabilitySHA256 = "capability_sha256"
        case resourcePolicySHA256 = "resource_policy_sha256"
        case profileSHA256 = "profile_sha256"
        case maximumTransportFrame = "maximum_transport_frame"
        case maximumPlaintext = "maximum_plaintext"
        case maximumRecords = "maximum_records"
        case maximumCumulativePlaintext = "maximum_cumulative_plaintext"
        case allowedNumericsClasses = "allowed_numerics_classes"
        case minimumMembers = "minimum_members"
        case maximumMembers = "maximum_members"
        case minimumMemberUsableBytes = "minimum_member_usable_bytes"
        case notAfter = "not_after"
    }
    static let fields = Set(CodingKeys.allCases.map(\.rawValue))

    /// The grant lease terms every cluster approval binds (the coordinator's
    /// `grantlease.Default`): renewal interval, time to live, disconnect grace.
    static let leaseTermsNanoseconds: [UInt64] = [40_000_000_000, 120_000_000_000, 90_000_000_000]

    /// The exact bytes the coordinator hashes into the approval binding and
    /// sends in every prepare frame of a cluster session.
    func canonicalPolicy() throws -> Data {
        guard let expiry = ClusterPairApproval.unixNanoseconds(rfc3339: notAfter) else {
            throw ClusterConfigurationError.invalid("Cluster approval not_after must be an RFC 3339 instant")
        }
        guard (2...4).contains(minimumMembers), (2...4).contains(maximumMembers), minimumMembers <= maximumMembers,
              minimumMemberUsableBytes > 0 else {
            throw ClusterConfigurationError.invalid("Cluster approval member bounds are outside 2...4")
        }
        var bytes = Data("darkbloom/coordinator-cluster-runtime-approval/v1\0".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
        }
        func text(_ value: String) { integer(UInt32(value.utf8.count)); bytes.append(contentsOf: value.utf8) }
        text(id); text(model); integer(generation)
        for digest in [placementPolicySHA256, artifactSHA256, nativeRuntimeSHA256, metallibSHA256,
                       resourceLibrarySHA256, capabilitySHA256, resourcePolicySHA256, profileSHA256] {
            guard ClusterConfigurationSyntax.hash(digest) else {
                throw ClusterConfigurationError.invalid("Cluster approval digests must be 64 lowercase hex characters")
            }
            let digits = Array(digest.utf8).map { $0 < 58 ? $0 - 48 : $0 - 87 }
            for index in stride(from: 0, to: 64, by: 2) { bytes.append(digits[index] << 4 | digits[index + 1]) }
        }
        bytes.append(contentsOf: [1, 1, schedule])
        integer(maximumTransportFrame); integer(maximumPlaintext)
        integer(maximumRecords); integer(maximumCumulativePlaintext)
        integer(expiry)
        bytes.append(UInt8(minimumMembers)); bytes.append(UInt8(maximumMembers))
        integer(minimumMemberUsableBytes)
        Self.leaseTermsNanoseconds.forEach { integer($0) }
        integer(UInt32(allowedNumericsClasses.count))
        allowedNumericsClasses.forEach(text)
        guard let policy = try? NativePairMemberPolicy(bytes), policy.cluster != nil else {
            throw ClusterConfigurationError.invalid("Cluster approval is outside the coordinator's policy bounds")
        }
        return bytes
    }
}
