import Foundation

/// Why a connected provider refuses new work (`busy_reason`). It rides beside
/// `status: draining` on `heartbeat` and on `register`; coordinators that do
/// not know the field still stop routing on the draining status.
public enum ProviderBusyReason: String, Codable, Sendable, CaseIterable {
    /// A local add-on (for example the sandbox VM host) holds the Mac.
    case addon
}

/// The optional busy fields of `register` and `heartbeat`, published as one
/// value so the three wire keys always describe the same hold.
public struct ProviderBusy: Sendable, Equatable {
    public var reason: ProviderBusyReason
    /// Unix milliseconds at which the provider entered this state
    /// (`busy_since_ms`).
    public var sinceMs: Int64
    /// The holding add-on's bundle identifier (`busy_addon`).
    public var addon: String?

    public init(reason: ProviderBusyReason, sinceMs: Int64, addon: String? = nil) {
        self.reason = reason
        self.sinceMs = sinceMs
        self.addon = addon
    }
}

extension ProviderMessage {
    /// The busy fields are flat wire keys; all three are omitted when not busy.
    static func encodeBusy(
        _ busy: ProviderBusy?, into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        guard let busy else { return }
        try container.encode(busy.reason, forKey: .busyReason)
        try container.encode(busy.sinceMs, forKey: .busySinceMs)
        try container.encodeIfPresent(busy.addon, forKey: .busyAddon)
    }

    /// An unknown future reason decodes as absent rather than failing the
    /// whole frame, like the other closed provider vocabularies.
    static func decodeBusy(from container: KeyedDecodingContainer<CodingKeys>) throws -> ProviderBusy? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: .busyReason),
              let reason = ProviderBusyReason(rawValue: raw) else { return nil }
        return ProviderBusy(
            reason: reason,
            sinceMs: try container.decodeIfPresent(Int64.self, forKey: .busySinceMs) ?? 0,
            addon: try container.decodeIfPresent(String.self, forKey: .busyAddon))
    }
}
