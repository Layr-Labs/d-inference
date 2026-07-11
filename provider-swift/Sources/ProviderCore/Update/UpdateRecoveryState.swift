import Foundation

public struct InstalledReleaseRecord: Codable, Sendable, Equatable {
    public var version: String
    public var releaseBundleHash: String?
    public var installedBundleHash: String
    public var binaryHash: String
    public var enclaveHash: String
    public var metallibHash: String
    public var installGeneration: UInt64
    public var installedAt: Double

    enum CodingKeys: String, CodingKey {
        case version
        case releaseBundleHash = "release_bundle_hash"
        case installedBundleHash = "installed_bundle_hash"
        case binaryHash = "binary_hash"
        case enclaveHash = "enclave_hash"
        case metallibHash = "metallib_hash"
        case installGeneration = "install_generation"
        case installedAt = "installed_at"
    }
}

public struct VerifiedPredecessor: Codable, Sendable, Equatable {
    public enum Layout: String, Codable, Sendable {
        case app
        case flat
    }

    public var release: InstalledReleaseRecord
    public var layout: Layout
    /// Paths are relative to the recovery root and validated before use.
    public var bundlePath: String
    public var binaryPath: String
    public var enclavePath: String
    public var metallibPath: String
    public var verifiedAt: Double

    enum CodingKeys: String, CodingKey {
        case release
        case layout
        case bundlePath = "bundle_path"
        case binaryPath = "binary_path"
        case enclavePath = "enclave_path"
        case metallibPath = "metallib_path"
        case verifiedAt = "verified_at"
    }
}

public struct PendingReleaseCandidate: Codable, Sendable, Equatable {
    public struct LaunchIntent: Codable, Sendable, Equatable {
        public var id: String
        public var preparedAt: Double
        public var baseline: ProviderLaunchSnapshot?
    }

    public var release: InstalledReleaseRecord
    public var failureCount: Int
    public var launchIntent: LaunchIntent?
    public var pendingAttemptID: String?
    public var attemptStartedAt: Double?
    public var healthySince: Double?
    public var healthyProcessStartedAt: Double?
    public var retryNotBefore: Double?
    public var rollbackBlockedReason: String?

    enum CodingKeys: String, CodingKey {
        case release
        case failureCount = "failure_count"
        case launchIntent = "launch_intent"
        case pendingAttemptID = "pending_attempt_id"
        case attemptStartedAt = "attempt_started_at"
        case healthySince = "healthy_since"
        case healthyProcessStartedAt = "healthy_process_started_at"
        case retryNotBefore = "retry_not_before"
        case rollbackBlockedReason = "rollback_blocked_reason"
    }
}

public struct FailedReleaseQuarantine: Codable, Sendable, Equatable {
    public var version: String
    public var failureCount: Int
    public var quarantinedAt: Double
    public var reason: String

    enum CodingKeys: String, CodingKey {
        case version
        case failureCount = "failure_count"
        case quarantinedAt = "quarantined_at"
        case reason
    }
}

/// Durable update state. Filesystem effects are deliberately absent: these
/// transitions are deterministic and exhaustively testable.
public struct UpdateRecoveryState: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    public static let rollbackThreshold = 3
    public static let defaultStabilizationSeconds: Double = 600

    public var schema: Int
    public var installGeneration: UInt64
    public var current: InstalledReleaseRecord?
    public var candidate: PendingReleaseCandidate?
    public var predecessor: VerifiedPredecessor?
    public var quarantine: FailedReleaseQuarantine?

    public init(
        schema: Int = UpdateRecoveryState.currentSchema,
        installGeneration: UInt64 = 0,
        current: InstalledReleaseRecord? = nil,
        candidate: PendingReleaseCandidate? = nil,
        predecessor: VerifiedPredecessor? = nil,
        quarantine: FailedReleaseQuarantine? = nil
    ) {
        self.schema = schema
        self.installGeneration = installGeneration
        self.current = current
        self.candidate = candidate
        self.predecessor = predecessor
        self.quarantine = quarantine
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case installGeneration = "install_generation"
        case current
        case candidate
        case predecessor
        case quarantine
    }

    public mutating func installCandidate(
        _ release: InstalledReleaseRecord,
        predecessor: VerifiedPredecessor,
        now: Double
    ) {
        if let superseded = candidate, superseded.failureCount > 0 {
            quarantine = FailedReleaseQuarantine(
                version: superseded.release.version,
                failureCount: superseded.failureCount,
                quarantinedAt: now,
                reason: "superseded by newer release \(release.version) after failed starts"
            )
        }
        installGeneration = release.installGeneration
        self.predecessor = predecessor
        candidate = PendingReleaseCandidate(
            release: release,
            failureCount: 0,
            launchIntent: nil,
            pendingAttemptID: nil,
            attemptStartedAt: nil,
            healthySince: nil,
            healthyProcessStartedAt: nil,
            retryNotBefore: nil,
            rollbackBlockedReason: nil
        )
        if quarantine?.version == release.version {
            quarantine = nil
        }
    }

    public mutating func prepareLaunchIntent(
        now: Double,
        baseline: ProviderLaunchSnapshot?
    ) -> Bool {
        guard var candidate, candidate.pendingAttemptID == nil else {
            return false
        }
        if let retryNotBefore = candidate.retryNotBefore,
           now < retryNotBefore {
            return false
        }
        candidate.launchIntent = PendingReleaseCandidate.LaunchIntent(
            id: UUID().uuidString,
            preparedAt: now,
            baseline: baseline
        )
        candidate.retryNotBefore = nil
        candidate.rollbackBlockedReason = nil
        self.candidate = candidate
        return true
    }

    public mutating func markLaunchIssued(now: Double) -> Bool {
        guard var candidate, candidate.launchIntent != nil else { return false }
        candidate.pendingAttemptID = candidate.launchIntent?.id
        candidate.attemptStartedAt = now
        candidate.launchIntent = nil
        candidate.healthySince = nil
        candidate.healthyProcessStartedAt = nil
        self.candidate = candidate
        return true
    }

    public mutating func reconcileLaunchIntent(
        snapshot: ProviderLaunchSnapshot?,
        now: Double
    ) -> Bool {
        guard let intent = candidate?.launchIntent else { return false }
        if snapshot?.provesLaunch(after: intent.baseline) == true {
            return markLaunchIssued(now: now)
        }
        candidate?.launchIntent = nil
        return false
    }

    public mutating func confirmRunningCandidate(
        version: String,
        processStartedAt: Double,
        now: Double
    ) -> Bool {
        guard var candidate,
              candidate.release.version == version,
              candidate.pendingAttemptID == nil
        else {
            return false
        }
        candidate.pendingAttemptID = candidate.launchIntent?.id
            ?? UUID().uuidString
        candidate.attemptStartedAt = now
        candidate.launchIntent = nil
        candidate.healthySince = now
        candidate.healthyProcessStartedAt = processStartedAt
        self.candidate = candidate
        return true
    }

    /// Count a failed launch exactly once. Repeated watchdog ticks cannot
    /// increment the counter because the pending attempt identifier is cleared.
    @discardableResult
    public mutating func recordPendingAttemptFailure(now: Double) -> Int? {
        guard var candidate, candidate.pendingAttemptID != nil else { return nil }
        if candidate.failureCount < Int.max {
            candidate.failureCount += 1
        }
        candidate.pendingAttemptID = nil
        candidate.attemptStartedAt = nil
        candidate.launchIntent = nil
        candidate.healthySince = nil
        candidate.healthyProcessStartedAt = nil
        candidate.retryNotBefore = nil
        candidate.rollbackBlockedReason = nil
        self.candidate = candidate
        return candidate.failureCount
    }

    public mutating func cancelPendingAttempt() {
        guard var candidate else { return }
        candidate.launchIntent = nil
        candidate.pendingAttemptID = nil
        candidate.attemptStartedAt = nil
        self.candidate = candidate
    }

    /// Observe the candidate's health signal. A candidate is promoted only
    /// after the signal remains continuously true for the stabilization window.
    /// Returns true exactly when promotion occurs.
    @discardableResult
    public mutating func observeCandidateHealth(
        healthySignal: Bool,
        processStartedAt: Double?,
        now: Double,
        stabilizationSeconds: Double = UpdateRecoveryState.defaultStabilizationSeconds
    ) -> Bool {
        guard var candidate else { return false }
        guard healthySignal else {
            candidate.healthySince = nil
            candidate.healthyProcessStartedAt = nil
            self.candidate = candidate
            return false
        }

        if candidate.healthySince == nil
            || candidate.healthyProcessStartedAt != processStartedAt
        {
            candidate.healthySince = now
            candidate.healthyProcessStartedAt = processStartedAt
            self.candidate = candidate
            return stabilizationSeconds <= 0
                ? promoteCandidate()
                : false
        }
        guard now - (candidate.healthySince ?? now) >= stabilizationSeconds else {
            self.candidate = candidate
            return false
        }
        self.candidate = candidate
        return promoteCandidate()
    }

    @discardableResult
    public mutating func promoteCandidate() -> Bool {
        guard let candidate else { return false }
        current = candidate.release
        self.candidate = nil
        return true
    }

    public mutating func completeRollback(now: Double, reason: String) {
        guard let failed = candidate, let predecessor else { return }
        current = predecessor.release
        quarantine = FailedReleaseQuarantine(
            version: failed.release.version,
            failureCount: failed.failureCount,
            quarantinedAt: now,
            reason: reason
        )
        candidate = nil
    }

    public mutating func deferRetryAfterRollbackFailure(now: Double, reason: String) {
        guard var candidate else { return }
        let exponent = max(0, min(candidate.failureCount - Self.rollbackThreshold, 4))
        let delay = min(3600.0, 300.0 * pow(2.0, Double(exponent)))
        candidate.pendingAttemptID = nil
        candidate.attemptStartedAt = nil
        candidate.healthySince = nil
        candidate.healthyProcessStartedAt = nil
        candidate.retryNotBefore = now + delay
        candidate.rollbackBlockedReason = reason
        self.candidate = candidate
    }

    public func isCandidateRetryBackedOff(now: Double) -> Bool {
        guard let retryNotBefore = candidate?.retryNotBefore else { return false }
        return now < retryNotBefore
    }

    /// Quarantine is narrow AND single-slot: it blocks only the exact failed
    /// version, and quarantining a newer failed version (v3) OVERWRITES the
    /// previous record (v2) — there is deliberately no multi-version
    /// quarantine list. After the overwrite, only normal monotonic version
    /// comparison keeps v2 from reinstalling (it is never strictly newer than
    /// the restored predecessor's successor). A strictly newer release
    /// escapes automatically without weakening anti-downgrade policy.
    /// Documented in threat model T-043.
    public func quarantineBlocks(version: String, manualOverride: Bool) -> Bool {
        guard !manualOverride, let quarantine else { return false }
        return quarantine.version == version
    }
}
