import Foundation

public struct WorkerSnapshot: Decodable, Sendable {
    public let schema: Int
    public let pid: Int32
    public let process_identity: KernelIdentity?
    public let written_at: Double
    public let started_at: Double
    public let coordinator_url: String?
    public let attestation_public_key: String?
    public let warm_models: [String]
    public let advertised_models: [String]?
    public let version: String
    public let stats: Stats
    public let trust: Trust?
    public struct Stats: Decodable, Sendable {
        public let requests_served: UInt64
        public let tokens_generated: UInt64
    }
    public struct Trust: Decodable, Sendable {
        public let status: String
        public let received_at: Double
        public let authorization: Authorization?
    }
    public struct Authorization: Decodable, Sendable {
        public let `protocol`: Int
        public let path: String
        public let expires_at: Double?
        public let session_id: String
        public let machine_id: String
    }
    public static func read() -> WorkerSnapshot? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".darkbloom/daemon-state.json")
        guard let bytes = try? SafeFile.read(url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }
}

public struct NetworkAttestation: Decodable, Sendable {
    public let provider_id: String
    public let se_public_key: String
    public let status: String
    public let app_attest_authorized: Bool
    public let authorization_expires_at: Double?
    public let models: [String]?
}

public struct ServingEvidence: Sendable {
    public let confirmed: Bool
    public let title: String
    public let detail: String
    public let validUntil: Double?
    public static let pending = ServingEvidence(confirmed: false, title: "Waiting for network verification", detail: "The coordinator must authorize the signed worker before it receives private requests.", validUntil: nil)

    /// This is a corroborated UI snapshot, never a credential. The coordinator
    /// continues to authorize EVERY handoff; none of these fields grants trust.
    public static func evaluate(snapshot s: WorkerSnapshot?, processVerified: Bool,
                                remote: [NetworkAttestation], fetchedAt: Double, now: Double) -> ServingEvidence {
        guard processVerified, let s, s.schema == 1, s.pid == s.process_identity?.pid,
              s.coordinator_url == "wss://api.darkbloom.dev/ws/provider",
              fresh(s.written_at, now: now), fresh(fetchedAt, now: now),
              s.started_at.isFinite, s.started_at > 0, s.started_at <= now,
              let trust = s.trust, trust.status == "online",
              fresh(trust.received_at, now: now), trust.received_at >= s.started_at,
              let a = trust.authorization, a.protocol == 1, a.path == "app_attest",
              !a.session_id.isEmpty, !a.machine_id.isEmpty,
              let localExpiry = a.expires_at, localExpiry.isFinite, localExpiry > now,
              let key = s.attestation_public_key, !key.isEmpty else { return .pending }
        let matches = remote.filter { $0.provider_id == a.session_id && $0.se_public_key == key }
        guard matches.count == 1, let r = matches.first, ["online", "serving"].contains(r.status), r.app_attest_authorized,
              let expiry = r.authorization_expires_at, expiry.isFinite, expiry > now else { return .pending }
        let deadline = min(localExpiry, expiry, s.written_at + 10, trust.received_at + 10, fetchedAt + 10)
        return .init(confirmed: true, title: "Authorized by Darkbloom", detail: "App Attest · signed worker · current network confirmation", validUntil: deadline)
    }

    static func fresh(_ value: Double, now: Double) -> Bool {
        value.isFinite && now.isFinite && value > 0 && value <= now + 2 && now - value < 10
    }

    public func isCurrent(at now: Double) -> Bool {
        confirmed && now.isFinite && (validUntil ?? 0) > now
    }
}
