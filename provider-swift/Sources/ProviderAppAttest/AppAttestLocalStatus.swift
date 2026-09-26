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
    /// The process-level context sent on the last `ready`.
    public var process: AppAttestProcessDiagnostics?
    /// The `key_history` sent on the last `ready`.
    public var keyHistory: AppAttestKeyHistory?
    /// The last failed attestation/assertion in this process.
    public var lastAppleFailure: AppAttestLastAppleFailure?

    public init(observedAt: Double, launchSession: AppAttestLaunchSession, bootTime: Int64? = nil,
                availabilityReason: AppAttestAvailabilityReason? = nil, operationStalledSeconds: Int? = nil,
                key: AppAttestKeyState? = nil, process: AppAttestProcessDiagnostics? = nil,
                keyHistory: AppAttestKeyHistory? = nil, lastAppleFailure: AppAttestLastAppleFailure? = nil) {
        self.observedAt = observedAt
        self.launchSession = launchSession
        self.bootTime = bootTime
        self.availabilityReason = availabilityReason
        self.operationStalledSeconds = operationStalledSeconds
        self.key = key
        self.process = process
        self.keyHistory = keyHistory
        self.lastAppleFailure = lastAppleFailure
    }

    // camelCase names: the daemon state file applies its snake-case strategy.
    enum CodingKeys: String, CodingKey {
        case observedAt, launchSession, bootTime, availabilityReason, operationStalledSeconds, key
        case process, keyHistory, lastAppleFailure
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
        process = try? c.decodeIfPresent(AppAttestProcessDiagnostics.self, forKey: .process)
        keyHistory = try? c.decodeIfPresent(AppAttestKeyHistory.self, forKey: .keyHistory)
        lastAppleFailure = try? c.decodeIfPresent(AppAttestLastAppleFailure.self, forKey: .lastAppleFailure)
    }
}

/// Closed summary of the last failed attestation/assertion reply, for doctor.
public struct AppAttestLastAppleFailure: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case attestation, assertion }

    public var observedAt: Double
    public var action: Action
    /// A `ShadowFailure` raw value (closed set).
    public var result: String
    public var nativeErrorChain: [AppAttestNativeErrorEntry]?

    public init(observedAt: Double, action: Action, result: String, nativeErrorChain: [AppAttestNativeErrorEntry]? = nil) {
        self.observedAt = observedAt
        self.action = action
        self.result = result
        self.nativeErrorChain = nativeErrorChain
    }

    /// Nil for `ok`, local-only results and non-exchange replies.
    init?(response: AppAttestShadowPayload, observedAt: Double) {
        guard let action = Action(rawValue: response.action), let raw = response.result,
              let failure = ShadowFailure(rawValue: raw),
              [.appleError, .appleInvalidKey, .appleUnavailable, .operationTimeout, .unsupported].contains(failure)
        else { return nil }
        self.init(observedAt: observedAt, action: action, result: failure.rawValue, nativeErrorChain: response.nativeErrorChain)
    }

    enum CodingKeys: String, CodingKey { case observedAt, action, result, nativeErrorChain }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try c.decode(Double.self, forKey: .observedAt)
        action = try c.decode(Action.self, forKey: .action)
        result = try c.decode(String.self, forKey: .result)
        nativeErrorChain = try? c.decodeIfPresent([AppAttestNativeErrorEntry].self, forKey: .nativeErrorChain)
    }
}
