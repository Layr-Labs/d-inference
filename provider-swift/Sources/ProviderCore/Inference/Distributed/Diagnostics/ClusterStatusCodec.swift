import Foundation

enum ClusterStatusCodec {
    static let maximumBytes = 16 * 1024
    static let nonceHeader = "X-Darkbloom-Cluster-Nonce"

    static func nonce(_ value: String) throws -> String {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw ClusterConfigurationError.invalid("Status requires a canonical request nonce")
        }
        return value
    }

    static func encode(_ value: ClusterLiveStatus) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value); bytes.append(10)
        guard bytes.count <= maximumBytes else { throw ClusterConfigurationError.invalid("Status exceeded its byte bound") }
        return bytes
    }

    static func decode(_ bytes: Data, nonce expectedNonce: String, binding: ClusterStatusBinding,
                       authenticationConfigured: Bool, port: UInt16) throws -> ClusterLiveStatus {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else {
            throw ClusterConfigurationError.invalid("Status exceeded its byte bound")
        }
        guard binding.peers.count == 2 else { throw ClusterConfigurationError.invalid("Malformed expected status binding") }
        let value = try JSONDecoder().decode(ClusterLiveStatus.self, from: bytes)
        // Exact canonical re-encoding rejects unknown/duplicate fields, alternate
        // integer syntax, omitted defaults and any trailing data.
        guard try encode(value) == bytes, value.schema == ClusterLiveStatus.schemaName,
              value.nonce == (try nonce(expectedNonce)), value.binding == binding,
              value.session.binding == binding, value.boundPort == port,
              value.authenticationConfigured == authenticationConfigured,
              ["starting", "serving", "draining", "stopping", "quarantined", "stopped"].contains(value.hostPhase),
              ["prepared", "starting", "ready", "draining", "stopping", "quarantined", "released"].contains(value.session.phase),
              // At most the most batch lanes a pair runs (`DistributedRequestQueue.maximumLanes`).
              (0...8).contains(value.acquisitions), value.session.members.count == 2,
              DistributedInstalledSpeculation(mode: binding.generationMode,
                  everyMemberAdvertisesHead: binding.peers.allSatisfy { $0.supportedGenerationModes.contains(.phaseSplitMTP) })
                  == .init(enabled: value.session.mtpEnabled, offReason: value.session.mtpOffReason),
              value.session.nativeBootstrapOwnerAuthenticated == value.session.nativeBootstrap.ownerAuthenticated,
              // S16: a verified peer only on an encrypted data plane, and only once both ranks are observed ready.
              value.session.peerVerified != true || value.session.encryptedDataPlane == true,
              (value.session.encryptedDataPlane == nil) == (value.session.peerVerified == nil),
              (1...3_600_000).contains(value.session.collectiveProgressLimitMilliseconds) else {
            throw ClusterConfigurationError.invalid("Status is stale, malformed or belongs to another saved setup")
        }
        if let epoch = value.session.observedMembershipEpoch { _ = try nonce(epoch) }
        guard (value.session.observedMembershipEpoch == nil) == (value.session.observedPrefillSchedule == nil),
              value.session.observedPrefillSchedule == nil || value.session.observedPrefillSchedule == binding.prefillSchedule else {
            throw ClusterConfigurationError.invalid("Status schedule observation differs")
        }
        guard (value.session.observedMembershipEpoch == nil) == (value.session.observedGenerationMode == nil),
              value.session.observedGenerationMode == nil || value.session.observedGenerationMode == binding.generationMode else {
            throw ClusterConfigurationError.invalid("Status generation mode observation differs")
        }
        for (rank, member) in value.session.members.enumerated() {
            guard member.rank == rank, member.peerID == binding.peers[rank].id,
                  rank == 0 ? member.transport == .localPipes : member.transport != .localPipes,
                  member.nativeReady == (member.requestCapacityBytes != nil),
                  member.requestCapacityBytes.map({ $0 > 0 }) ?? true,
                  !member.ownerReleaseAcknowledged || member.nativeCleanupObserved else {
                throw ClusterConfigurationError.invalid("Status member observation differs")
            }
            if let termination = member.ownerTermination {
                guard (termination.kind == .launchFailed) == (termination.status == nil) else {
                    throw ClusterConfigurationError.invalid("Malformed owner termination observation")
                }
            }
        }
        if let admission = value.session.admission {
            guard admission.requestsServed >= 0, admission.keepWarmExchanges >= 0 else {
                throw ClusterConfigurationError.invalid("Status counters are negative")
            }
        }
        let admitted = value.session.admission
        let sessionReady = value.session.ready
        // A pair with batch lanes admits while some lanes are held; the pair
        // itself reports `activeRequest` once every lane is taken.
        let admits = value.ready && admitted?.valid == true && admitted?.activeRequest == false
            && admitted?.draining == false
        guard !sessionReady || (value.session.observedMembershipEpoch != nil
            && value.session.members.allSatisfy(\.nativeReady) && admitted?.valid == true),
              value.ready == (value.hostPhase == "serving" && !value.failed && sessionReady),
              value.acquisitions == 0 ? value.admissionAvailable == admits : (!value.admissionAvailable || admits),
              value.quarantined == (value.hostPhase == "quarantined" || value.session.phase == "quarantined") else {
            throw ClusterConfigurationError.invalid("Inconsistent status readiness observation")
        }
        return value
    }
}
