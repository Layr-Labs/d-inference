import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Unenroll {
    /// Selected from the interactive choice or directly with --keep-serving.
    /// This path must never invoke full-exit cleanup.
    func prepareMDMRemovalWhileServing(
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) throws {
        guard !force else {
            throw ValidationError("--force cannot be combined with --keep-serving; migration retains all local data.")
        }
        try Self.requireAppAttestOS(osMajor)
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let coordinator = snapshot.config.coordinator.url
        let now = Date().timeIntervalSince1970
        let authorization = DaemonStateFile.read()?.currentProviderAuthorization(
            coordinatorURL: coordinator, now: now)
        guard ProviderAuthorizationReadiness.removalReady(authorization, now: now) else {
            printError(ProviderAuthorizationReadiness.summary(authorization, now: now))
            throw ExitCode.failure
        }

        switch checkMDMEnrollment(coordinatorURL: coordinator) {
        case .notEnrolled:
            print("App Attest authorizes this connection. No Darkbloom MDM enrollment needs removal.")
            return
        case .enrolledOtherMDM:
            print("App Attest authorizes this connection. Keep your organization's management profile installed.")
            return
        case .checkFailed:
            printError("The installed management profile could not be identified. No removal guidance was opened; retry darkbloom doctor.")
            throw ExitCode.failure
        case .enrolledDarkbloom:
            break
        }
        guard let target = DarkbloomMDMRemoval.installedTarget(
            coordinatorURL: coordinator,
            allowAdministratorPrompt: isatty(STDIN_FILENO) != 0,
            beforeAdministratorPrompt: {
                print("Administrator access is needed to read the device's installed profiles.")
                print("This only reads profile details; you choose removal in System Settings.")
            }) else {
            printError("Could not verify the exact Darkbloom enrollment profile and server. Keep installed profiles in place and contact support.")
            throw ExitCode.failure
        }

        // Profile inventory can be slow. Re-read the daemon's current status
        // immediately before offering removal, so inspection never extends a
        // short serving lease or hides a disconnect/revocation during the read.
        let checkedAt = Date().timeIntervalSince1970
        let current = DaemonStateFile.read()?.currentProviderAuthorization(
            coordinatorURL: coordinator, now: checkedAt)
        guard ProviderAuthorizationReadiness.removalReady(current, now: checkedAt) else {
            printError("App Attest readiness changed during the profile check. Keep the profile installed and retry after fresh verification.")
            throw ExitCode.failure
        }

        print("The coordinator confirms that App Attest authorizes this running provider.")
        print("In System Settings → General → Device Management, remove only:")
        print("  \(target.displayName)")
        print("  Identifier: \(target.identifier)")
        print("  Server: \(target.serverURL)")
        print("Keep any organization management profiles installed.")
        print("Your Darkbloom account, machine identity, App Attest keys, and model data are retained.")
        print("Keep the provider running during removal, then run darkbloom doctor.")
        print("If authorization expires or is revoked, new inference waits for fresh verification.")
        if !noOpen { EnrollmentService().openProfilesPaneForRemoval() }
    }
}
