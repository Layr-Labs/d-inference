import ArgumentParser
import Foundation
import ProviderCore

struct Unenroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Leave Darkbloom, or remove the retired Darkbloom MDM profile and keep serving.",
        discussion: """
        Darkbloom verifies Macs with App Attest only; its MDM profile is retired
        and no longer used. macOS lets only you remove a profile, so this
        command opens System Settings at it and names exactly which one.

        Running unenroll interactively offers two choices: fully exit
        Darkbloom, or remove only the old Darkbloom MDM profile and keep
        serving. Removing the profile keeps your account, keys, and data.
        --keep-serving selects it directly; --force selects full exit and
        confirms cleanup.
        """
    )

    @Flag(help: "Fully exit Darkbloom and confirm local-data cleanup without prompting.")
    var force = false

    @Flag(help: "Don't open System Settings.")
    var noOpen = false

    @OptionGroup var configOptions: ConfigOptions

    @Flag(help: "Remove only the retired Darkbloom MDM profile; keep serving, account, keys, and local data.")
    var keepServing = false

    mutating func run() async throws {
        let mode = try chooseUnenrollmentMode()
        try await Self.performUnenrollment(
            mode: mode,
            stopProvider: { try await Self.stopProviderBeforeUnenrollment() },
            leave: { performFullUnenrollment() },
            removeProfile: { try guideRetiredProfileRemoval() }
        )
    }

    private func performFullUnenrollment() {
        print("Darkbloom Unenrollment")
        print()

        let enrollment = checkMDMEnrollment()
        switch enrollment {
        case .enrolledDarkbloom:
            print("The retired Darkbloom MDM profile is installed. To remove it:")
            print("  System Settings → General → Device Management")
            print("  Click on the Darkbloom profile → Remove")
            print()
            if !noOpen {
                print("Opening System Settings...")
                RetiredMDMProfile.openSystemSettings()
            }
        case .enrolledOtherMDM(let serverURL):
            if enrollment.otherInstall != nil {
                print("This Mac has \(describeOtherMDM(enrollment)) — not this install's.")
            } else {
                print("This Mac is managed by a different MDM (\(serverURL)) — not Darkbloom's.")
            }
            print("Nothing to remove on the macOS side.")
        case .notEnrolled:
            print("No Darkbloom MDM profile found. Nothing to remove on the macOS side.")
        case .checkFailed:
            print("Couldn't determine MDM state (the profiles tool failed).")
            print("Check System Settings → General → Device Management yourself.")
            if !noOpen {
                print("Opening System Settings...")
                RetiredMDMProfile.openSystemSettings()
            }
        }

        print()
        print("Local data cleanup will remove:")
        let environment = BuildEnvironment.current
        let legacy = environment.legacyConfigDirectoryNames.map { "~/\($0)/" }.joined(separator: ", ")
        print("  • Config dir:    ~/\(environment.configDirectoryName)/"
            + (legacy.isEmpty ? "" : "  (and legacy \(legacy))"))
        print("  • Auth token:    ~/\(environment.installDirectoryName)/auth_token")
        print("  • Legacy keys:   ~/\(environment.installDirectoryName)/{wallet_key,enclave_key.data,…}")
        print("  • Signing key:   Secure Enclave attestation key")
        print()

        let proceed: Bool
        if force {
            proceed = true
        } else {
            print("Type 'yes' to confirm:")
            let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            proceed = line.lowercased() == "yes"
        }

        if proceed {
            LocalDataCleanup.purge()
            print("  ✓ Local data cleaned up.")
        } else {
            print("  Skipped local cleanup.")
        }
    }
}
