import Foundation

/// Pure freshness checks for operator guidance. The coordinator independently
/// checks authorization before dispatching each private inference request.
public enum ProviderAuthorizationReadiness {
    public static let snapshotMaxAge: Double = 10

    /// Removal guidance: the coordinator decision itself must be fresh, so a
    /// delayed revocation cannot be hidden behind a lease that has time left.
    public static func currentStatus(
        _ authorization: ProviderAuthorizationStatus?,
        status: String?, writtenAt: Double, receivedAt: Double,
        startedAt: Double, now: Double, processMatches: Bool,
        coordinatorMatches: Bool
    ) -> ProviderAuthorizationStatus? {
        guard let live = liveDecision(authorization, status: status, writtenAt: writtenAt,
                                      receivedAt: receivedAt, startedAt: startedAt, now: now,
                                      processMatches: processMatches, coordinatorMatches: coordinatorMatches),
              now - receivedAt <= snapshotMaxAge
        else { return nil }
        return live
    }

    /// Status and doctor: an unexpired App Attest lease is still the
    /// coordinator's grant when its latest renewal arrived more than
    /// `snapshotMaxAge` ago, so one delayed renewal does not show legacy trust.
    /// Other decisions keep the renewal window.
    public static func displayedStatus(
        _ authorization: ProviderAuthorizationStatus?,
        status: String?, writtenAt: Double, receivedAt: Double,
        startedAt: Double, now: Double, processMatches: Bool,
        coordinatorMatches: Bool
    ) -> ProviderAuthorizationStatus? {
        guard let live = liveDecision(authorization, status: status, writtenAt: writtenAt,
                                      receivedAt: receivedAt, startedAt: startedAt, now: now,
                                      processMatches: processMatches, coordinatorMatches: coordinatorMatches),
              now - receivedAt <= snapshotMaxAge || live.hasCurrentAppAttestAuthorization(now: now)
        else { return nil }
        return live
    }

    /// The latest decision this live process received from the expected
    /// coordinator, written by a daemon that is still updating its snapshot.
    private static func liveDecision(
        _ authorization: ProviderAuthorizationStatus?,
        status: String?, writtenAt: Double, receivedAt: Double,
        startedAt: Double, now: Double, processMatches: Bool,
        coordinatorMatches: Bool
    ) -> ProviderAuthorizationStatus? {
        guard processMatches, coordinatorMatches, now.isFinite,
              writtenAt.isFinite, receivedAt.isFinite, startedAt.isFinite,
              writtenAt <= now + 2, now - writtenAt <= snapshotMaxAge,
              receivedAt >= startedAt, receivedAt <= now + 2,
              status == "online", let authorization,
              authorization.protocolVersion == 1
        else { return nil }
        return authorization
    }

    public static func removalReady(_ authorization: ProviderAuthorizationStatus?, now: Double) -> Bool {
        guard let authorization else { return false }
        return authorization.mdmRemovalReady
            && authorization.hasCurrentAppAttestAuthorization(now: now)
    }

    public static func summary(
        _ authorization: ProviderAuthorizationStatus?, now: Double,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> String {
        guard let authorization else {
            return "App Attest authorization is unconfirmed; keep any existing management profiles installed until this running provider receives fresh coordinator readiness."
        }
        if authorization.hasCurrentAppAttestAuthorization(now: now) {
            return "App Attest authorizes this connection. " + (authorization.mdmRemovalReady
                ? "Darkbloom MDM removal is available: run darkbloom unenroll and choose App Attest."
                : "Darkbloom MDM removal is not enabled for this machine yet.")
        }
        if authorization.path == "legacy" {
            return "Serving through legacy verification; keep the Darkbloom MDM profile."
        }
        if authorization.appAttestAvailable {
            return "The coordinator supports App Attest, but this connection is not currently qualified. "
                + "Keep existing management in place. " + authorization.reason
        }
        if ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion) {
            return "This coordinator has not enabled App Attest serving. New macOS 27+ setup remains pending; "
                + "check `darkbloom doctor` and contact support. Keep existing management profiles installed."
        }
        return "This coordinator has not enabled App Attest serving; legacy enrollment is still required on older macOS. "
            + ProviderOnboardingPolicy.retirementNotice
    }
}

extension DaemonState {
    /// Uses the kernel process identity, never a PID-only existence test. This
    /// snapshot is read-only local guidance and is not a serving credential.
    public func currentProviderAuthorization(
        coordinatorURL expectedCoordinator: String,
        now: Double = Date().timeIntervalSince1970,
        readProcessIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> ProviderAuthorizationStatus? {
        let matches = snapshotMatches(coordinatorURL: expectedCoordinator, readProcessIdentity: readProcessIdentity)
        return ProviderAuthorizationReadiness.currentStatus(
            trust?.authorization, status: trust?.status,
            writtenAt: writtenAt, receivedAt: trust?.receivedAt ?? 0,
            startedAt: startedAt, now: now,
            processMatches: matches.process, coordinatorMatches: matches.coordinator)
    }

    /// For `status` and `doctor` output; removal decisions use
    /// `currentProviderAuthorization`.
    public func displayedProviderAuthorization(
        coordinatorURL expectedCoordinator: String,
        now: Double = Date().timeIntervalSince1970,
        readProcessIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> ProviderAuthorizationStatus? {
        let matches = snapshotMatches(coordinatorURL: expectedCoordinator, readProcessIdentity: readProcessIdentity)
        return ProviderAuthorizationReadiness.displayedStatus(
            trust?.authorization, status: trust?.status,
            writtenAt: writtenAt, receivedAt: trust?.receivedAt ?? 0,
            startedAt: startedAt, now: now,
            processMatches: matches.process, coordinatorMatches: matches.coordinator)
    }

    /// Whether this snapshot was written by the still-running daemon process
    /// and describes a connection to the expected coordinator.
    private func snapshotMatches(
        coordinatorURL expectedCoordinator: String,
        readProcessIdentity: (Int32) -> ProcessIdentity?
    ) -> (process: Bool, coordinator: Bool) {
        let process = processIdentity.map {
            $0.pid == pid && readProcessIdentity(pid) == $0
        } ?? false
        let coordinator = coordinatorUrl.map {
            coordinatorHTTPBase($0) == coordinatorHTTPBase(expectedCoordinator)
        } ?? false
        return (process, coordinator)
    }
}
