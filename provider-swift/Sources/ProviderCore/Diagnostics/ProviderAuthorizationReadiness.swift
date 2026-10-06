import Foundation

/// Pure freshness checks for operator guidance. The coordinator independently
/// checks authorization before dispatching each private inference request.
public enum ProviderAuthorizationReadiness {
    public static let snapshotMaxAge: Double = 10

    public static func currentStatus(
        _ authorization: ProviderAuthorizationStatus?,
        status: String?, writtenAt: Double, receivedAt: Double,
        startedAt: Double, now: Double, processMatches: Bool,
        coordinatorMatches: Bool
    ) -> ProviderAuthorizationStatus? {
        guard processMatches, coordinatorMatches, now.isFinite,
              writtenAt.isFinite, receivedAt.isFinite, startedAt.isFinite,
              writtenAt <= now + 2, now - writtenAt <= snapshotMaxAge,
              receivedAt >= startedAt, receivedAt <= now + 2,
              now - receivedAt <= snapshotMaxAge,
              status == "online", let authorization,
              authorization.protocolVersion == 1
        else { return nil }
        return authorization
    }

    /// Checks current coordinator approval. Removal also requires local enrollment
    /// and an exact Darkbloom profile match from `DarkbloomMDMRemoval`.
    public static func removalReady(_ authorization: ProviderAuthorizationStatus?, now: Double) -> Bool {
        guard let authorization else { return false }
        return authorization.mdmRemovalReady
            && authorization.hasCurrentAppAttestAuthorization(now: now)
    }

    /// Called only after confirming current App Attest authorization. Coordinator
    /// approval cannot establish which profiles are installed on this Mac.
    private static func removalAdvice(
        _ authorization: ProviderAuthorizationStatus, enrollment: MDMEnrollmentState
    ) -> String {
        switch enrollment {
        case .enrolledDarkbloom:
            return authorization.mdmRemovalReady
                ? "Darkbloom MDM removal is available: run darkbloom unenroll and choose option 2. Keep any organization management profiles installed."
                : "The coordinator has not enabled Darkbloom MDM removal. Keep the Darkbloom MDM profile installed."
        case .enrolledOtherMDM(let serverURL):
            return "No Darkbloom MDM profile is installed. This Mac is managed by another MDM "
                + "(\(serverURL)); keep that profile installed."
        case .notEnrolled:
            return "No Darkbloom MDM profile is installed, so no action is needed. Keep the provider running."
        case .checkFailed:
            return "The installed management profiles could not be read, so no removal guidance is offered; "
                + "keep existing profiles installed."
        }
    }

    /// - Parameter enrollment: This Mac's observed `checkMDMEnrollment` result.
    public static func summary(
        _ authorization: ProviderAuthorizationStatus?, enrollment: MDMEnrollmentState, now: Double,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> String {
        guard let authorization else {
            return "App Attest authorization is unconfirmed; keep any existing management profiles installed until this running provider receives fresh coordinator readiness."
        }
        if authorization.hasCurrentAppAttestAuthorization(now: now) {
            return "App Attest authorizes this connection. "
                + removalAdvice(authorization, enrollment: enrollment)
                + " Base rewards have separate eligibility checks."
        }
        if authorization.path == "legacy" {
            return "Serving through legacy verification; keep the Darkbloom MDM profile. Legacy verification alone does not qualify for base rewards."
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
        let processMatches = processIdentity.map {
            $0.pid == pid && readProcessIdentity(pid) == $0
        } ?? false
        let coordinatorMatches = coordinatorUrl.map {
            coordinatorHTTPBase($0) == coordinatorHTTPBase(expectedCoordinator)
        } ?? false
        return ProviderAuthorizationReadiness.currentStatus(
            trust?.authorization, status: trust?.status,
            writtenAt: writtenAt, receivedAt: trust?.receivedAt ?? 0,
            startedAt: startedAt, now: now,
            processMatches: processMatches, coordinatorMatches: coordinatorMatches)
    }
}
