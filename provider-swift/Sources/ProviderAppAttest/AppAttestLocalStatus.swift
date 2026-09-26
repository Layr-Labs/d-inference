import Foundation

/// The running provider's last local App Attest observations, published in the
/// daemon state file for `darkbloom doctor`. Local diagnostics only: the
/// coordinator's verdict remains the sole serving authorization.
public struct AppAttestLocalStatus: Codable, Sendable, Equatable {
    /// Unix seconds when this snapshot was taken.
    public var observedAt: Double
    /// Launch context of the provider process, not of the CLI reading it.
    public var launchSession: AppAttestLaunchSession
    public var bootTime: Int64?
    /// Closed availability reason from the last failed `ready` reply.
    public var availabilityReason: AppAttestAvailabilityReason?
    /// Set while an Apple call has held admission past `AppleOperationStall.threshold`.
    public var operationStalledSeconds: Int?
    /// Nil when Keychain could not be read or the request named no key scope.
    public var key: AppAttestKeyState?

    public init(observedAt: Double, launchSession: AppAttestLaunchSession, bootTime: Int64? = nil,
                availabilityReason: AppAttestAvailabilityReason? = nil, operationStalledSeconds: Int? = nil,
                key: AppAttestKeyState? = nil) {
        self.observedAt = observedAt
        self.launchSession = launchSession
        self.bootTime = bootTime
        self.availabilityReason = availabilityReason
        self.operationStalledSeconds = operationStalledSeconds
        self.key = key
    }

    // camelCase names: the daemon state file applies its snake-case strategy.
    enum CodingKeys: String, CodingKey {
        case observedAt, launchSession, bootTime, availabilityReason, operationStalledSeconds, key
    }

    /// A CLI and daemon of different versions share the state file during an
    /// update. An enum value this build does not know must not make the whole
    /// daemon snapshot unreadable, so it degrades to unknown/absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try c.decode(Double.self, forKey: .observedAt)
        launchSession = (try? c.decodeIfPresent(AppAttestLaunchSession.self, forKey: .launchSession)) ?? .unknown
        bootTime = try? c.decodeIfPresent(Int64.self, forKey: .bootTime)
        availabilityReason = try? c.decodeIfPresent(AppAttestAvailabilityReason.self, forKey: .availabilityReason)
        operationStalledSeconds = try? c.decodeIfPresent(Int.self, forKey: .operationStalledSeconds)
        key = try? c.decodeIfPresent(AppAttestKeyState.self, forKey: .key)
    }
}
