import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Unenroll {
    /// Selected from the interactive choice or directly with --keep-serving.
    /// It never invokes full-exit cleanup and never removes a profile itself:
    /// it names the retired Darkbloom profile and opens System Settings.
    func guideRetiredProfileRemoval() throws {
        guard !force else {
            throw ValidationError("--force cannot be combined with --keep-serving; removing the profile retains all local data.")
        }
        let coordinator = (try? loadRuntimeConfiguration(configPath: configOptions.config))?.config.coordinator.url
            ?? BuildEnvironment.current.coordinatorHTTPURL
        let interactive = isatty(STDIN_FILENO) != 0
        try Self.guideRetiredProfileRemoval(
            enrollment: checkMDMEnrollment(),
            identifyProfile: {
                DarkbloomMDMRemoval.installedTarget(
                    coordinatorURL: coordinator, allowAdministratorPrompt: interactive,
                    beforeAdministratorPrompt: {
                        print("Administrator access is needed to read the device's installed profiles.")
                        print("This only reads profile details; you choose removal in System Settings.")
                    })
            },
            openSettings: noOpen ? nil : { DarkbloomMDMRemoval.openProfilesSettings() },
            writeLine: { print($0) }, writeError: { printError($0) })
    }

    static func guideRetiredProfileRemoval(
        enrollment: MDMEnrollmentState,
        identifyProfile: () -> DarkbloomMDMRemovalTarget?,
        openSettings: (() -> Void)?,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        writeLine: (String) -> Void,
        writeError: (String) -> Void
    ) throws {
        let serverURL: String
        switch enrollment {
        case .notEnrolled:
            writeLine("No Darkbloom MDM profile is installed; nothing to remove.")
            return
        case .enrolledOtherMDM:
            if enrollment.otherInstall != nil {
                writeLine("This Mac has \(describeOtherMDM(enrollment)); this install does not remove it.")
            } else {
                writeLine("This Mac's management profile is not Darkbloom's. Keep your organization's profile installed.")
            }
            return
        case .checkFailed:
            writeError("Couldn't read this Mac's MDM enrollment (the profiles tool failed). Nothing was opened; retry, or check System Settings → General → Device Management.")
            throw ExitCode.failure
        case .enrolledDarkbloom(let server):
            serverURL = server
        }

        writeLine("Darkbloom no longer uses its MDM profile: Macs are verified with App Attest.")
        writeLine("In System Settings → General → Device Management, remove only:")
        if let target = identifyProfile() {
            writeLine("  \(target.displayName)")
            writeLine("  Identifier: \(target.identifier)")
            writeLine("  Server: \(target.serverURL)")
        } else {
            writeLine("  the profile named \"Darkbloom Provider Enrollment\" (server \(serverURL))")
            writeLine("If no profile has exactly this name, remove nothing.")
        }
        writeLine("Keep any profile from your employer or school.")
        writeLine("Your Darkbloom account, machine identity, App Attest keys, and model data are kept; the provider keeps running.")
        if !ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion) {
            writeLine("This Mac needs macOS 27 or later to serve (App Attest). \(ProviderOnboardingPolicy.upgradeGuidance)")
        }
        openSettings?()
    }
}
