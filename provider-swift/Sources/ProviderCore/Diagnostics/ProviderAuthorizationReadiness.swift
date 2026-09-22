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
        if let legacyReason = legacyDenialDescription(authorization.reason) {
            return "Legacy serving is not authorized on this connection (\(authorization.reason)): "
                + legacyReason + " Keep the Darkbloom MDM profile installed; App Attest has not authorized this connection."
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

    private static func legacyDenialDescription(_ reason: String) -> String? {
        switch reason {
        case "legacy_state_restore_pending": return "the coordinator has not completed state restoration."
        case "legacy_runtime_unverified", "legacy_runtime_manifest_unverified":
            return "the coordinator has not verified the signed runtime."
        case "legacy_private_transport_unavailable": return "the private inference transport is unavailable."
        case "legacy_sip_unverified": return "the current challenge has not verified System Integrity Protection."
        case "legacy_release_evidence_missing": return "current signed-release evidence is missing."
        case "legacy_code_identity_unverified": return "APNs code identity has not been verified for this connection."
        case "legacy_privacy_posture_unverified": return "the required private-inference posture is unverified."
        case "legacy_challenge_stale": return "there is no fresh coordinator challenge proof."
        case "legacy_connection_unavailable", "legacy_trust_below_minimum", "legacy_serving_gate_unavailable":
            return "a required coordinator serving gate is unavailable."
        default: return nil
        }
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
