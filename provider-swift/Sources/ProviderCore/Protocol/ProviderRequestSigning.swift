import Foundation

/// `register.request_signing`: the coordinator request-signing keys this build
/// pins, so the coordinator signs the requests it sends here. A hint only: a
/// peer that changes it can only cause refusals. Mirrors
/// `ProviderRequestSigning` (Go).
public struct ProviderRequestSigning: Codable, Sendable, Equatable {
    public struct Pin: Codable, Sendable, Equatable {
        public let keyID: String
        public let expiresAtMs: Int64

        public init(keyID: String, expiresAtMs: Int64) {
            self.keyID = keyID
            self.expiresAtMs = expiresAtMs
        }

        enum CodingKeys: String, CodingKey {
            case keyID = "kid"
            case expiresAtMs = "expires_at_ms"
        }
    }

    /// The pins that have not expired by this Mac's clock.
    public let keys: [Pin]

    public init(keys: [Pin]) {
        self.keys = keys
    }

    /// The registration of `pins`, without those expired at `now`; nil when none is left.
    public init?(pins: [CoordinatorRequestSigningPin], now: Date) {
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let live = pins.filter { $0.expiresAtMs > nowMs }.map { Pin(keyID: $0.keyID, expiresAtMs: $0.expiresAtMs) }
        guard !live.isEmpty else { return nil }
        self.init(keys: live)
    }
}
