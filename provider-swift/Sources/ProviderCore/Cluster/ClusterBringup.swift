/// ClusterBringup -- bring a node into its cluster and produce a ready
/// `DistributedInferenceEngine`.
///
/// This is the orchestration the provider start path runs (when a `ClusterPlan`
/// is present) instead of standing up a single-node `BatchScheduler`:
///
///   1. Establish encrypted sessions with ring neighbors via the handshake
///      (`ClusterHandshakeRunner` over `HandshakeChannel`), authenticated
///      against the coordinator-signed roster.
///   2. Materialize the MLX ring hostfile + env (`MLXRingEnvironment`) and
///      initialize the distributed group (`MLXDistributedGroup`).
///   3. Build the `DistributedInferenceEngine` with a runtime that wraps the
///      ring transport + the neighbor sessions.
///
/// The handshake + session derivation + engine assembly are all real and
/// testable on one machine (with the in-memory channel + loopback runtime). The
/// two hardware-bound steps — opening real sockets to neighbors and the MLX
/// ring `init/send/recv` — are isolated behind `HandshakeChannel` and
/// `ClusterRuntime`, so this orchestration is exercised end-to-end in tests and
/// reused unchanged on the two Macs.

import Foundation

public struct ClusterBringupResult: Sendable {
    /// Session sealing toward the next rank (nil on the tail).
    public let sendSession: ClusterSession?
    /// Session opening from the previous rank (nil on the head).
    public let recvSession: ClusterSession?
    /// MLX ring environment to apply before group init (host-bound).
    public let ringEnv: [String: String]
}

public enum ClusterBringupError: Error, Sendable {
    case noNeighbors
}

public enum ClusterBringup {
    /// Run the pairwise handshakes with this node's ring neighbors.
    ///
    /// Ordering rule (matches `ClusterHandshake`): for each adjacent pair the
    /// LOWER nodeId is the initiator. The caller supplies a `HandshakeChannel`
    /// to each neighbor (a dialed/accepted socket on hardware; an in-memory pair
    /// in tests). Returns the derived sessions for the prev/next links.
    public static func handshakeNeighbors(
        plan: ClusterPlan,
        signer: any AttestationSigner,
        roster: ClusterRosterBody,
        channelToPrev: (any HandshakeChannel)?,
        channelToNext: (any HandshakeChannel)?
    ) async throws -> (recv: ClusterSession?, send: ClusterSession?) {
        let (prevId, nextId) = plan.neighborNodeIds()

        // Session with the PREVIOUS neighbor (it is upstream; we receive from it).
        var recvSession: ClusterSession?
        if let prevId, let channel = channelToPrev {
            recvSession = try await runPair(
                local: plan.nodeId, peer: prevId, clusterId: plan.clusterId,
                signer: signer, roster: roster, channel: channel)
        }

        // Session with the NEXT neighbor (downstream; we send to it).
        var sendSession: ClusterSession?
        if let nextId, let channel = channelToNext {
            sendSession = try await runPair(
                local: plan.nodeId, peer: nextId, clusterId: plan.clusterId,
                signer: signer, roster: roster, channel: channel)
        }

        return (recvSession, sendSession)
    }

    /// Decide initiator vs responder by nodeId ordering, then run the handshake.
    private static func runPair(
        local: String, peer: String, clusterId: String,
        signer: any AttestationSigner, roster: ClusterRosterBody,
        channel: any HandshakeChannel
    ) async throws -> ClusterSession {
        if local < peer {
            return try await ClusterHandshakeRunner.runInitiator(
                clusterId: clusterId, localNodeId: local, signer: signer, roster: roster, channel: channel)
        } else {
            return try await ClusterHandshakeRunner.runResponder(
                localNodeId: local, signer: signer, roster: roster, channel: channel)
        }
    }
}
