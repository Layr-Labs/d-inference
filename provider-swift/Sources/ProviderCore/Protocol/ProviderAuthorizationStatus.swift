import Foundation

/// Coordinator-issued status for the current connection. This is diagnostics
/// and migration guidance, never a local grant to serve private requests.
public struct ProviderAuthorizationStatus: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var appAttestAvailable: Bool
    public var path: String
    public var expiresAt: Double?
    public var mdmRemovalReady: Bool
    public var reason: String
    public var sessionID: String
    public var machineID: String

    public init(
        protocolVersion: Int = 1, appAttestAvailable: Bool, path: String,
        expiresAt: Double? = nil, mdmRemovalReady: Bool = false,
        reason: String = "", sessionID: String, machineID: String
    ) {
        self.protocolVersion = protocolVersion
        self.appAttestAvailable = appAttestAvailable
        self.path = path
        self.expiresAt = expiresAt
        self.mdmRemovalReady = mdmRemovalReady
        self.reason = reason
        self.sessionID = sessionID
        self.machineID = machineID
    }

    public func hasCurrentAppAttestAuthorization(now: Double) -> Bool {
        guard protocolVersion == 1, path == "app_attest",
              !sessionID.isEmpty, !machineID.isEmpty,
              let expiresAt, expiresAt.isFinite, now.isFinite else { return false }
        return expiresAt > now
    }

    /// Renewing an unchanged lease every few seconds must update diagnostics
    /// without creating a fleet-wide stream of duplicate info-level messages.
    static func sameDiagnosticDecision(_ lhs: Self?, _ rhs: Self?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.protocolVersion == rhs.protocolVersion
                && lhs.appAttestAvailable == rhs.appAttestAvailable
                && lhs.path == rhs.path && lhs.mdmRemovalReady == rhs.mdmRemovalReady
                && lhs.reason == rhs.reason && lhs.sessionID == rhs.sessionID
                && lhs.machineID == rhs.machineID
        default: return false
        }
    }

    // DaemonStateFile uses convertFromSnakeCase, while the wire codec uses
    // explicit keys. Accept both decoder projections; emit only wire keys.
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case path, reason
        case appAttestAvailable, expiresAt, mdmRemovalReady, sessionId, machineId
        case appAttestAvailableWire = "app_attest_available"
        case expiresAtWire = "expires_at"
        case mdmRemovalReadyWire = "mdm_removal_ready"
        case sessionIDWire = "session_id"
        case machineIDWire = "machine_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        path = try c.decode(String.self, forKey: .path)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        appAttestAvailable = try c.decodeIfPresent(Bool.self, forKey: .appAttestAvailableWire)
            ?? c.decodeIfPresent(Bool.self, forKey: .appAttestAvailable) ?? false
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAtWire)
            ?? c.decodeIfPresent(Double.self, forKey: .expiresAt)
        mdmRemovalReady = try c.decodeIfPresent(Bool.self, forKey: .mdmRemovalReadyWire)
            ?? c.decodeIfPresent(Bool.self, forKey: .mdmRemovalReady) ?? false
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionIDWire)
            ?? c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        machineID = try c.decodeIfPresent(String.self, forKey: .machineIDWire)
            ?? c.decodeIfPresent(String.self, forKey: .machineId) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(appAttestAvailable, forKey: .appAttestAvailableWire)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAtWire)
        try c.encode(mdmRemovalReady, forKey: .mdmRemovalReadyWire)
        try c.encode(reason, forKey: .reason)
        try c.encode(sessionID, forKey: .sessionIDWire)
        try c.encode(machineID, forKey: .machineIDWire)
    }
}
