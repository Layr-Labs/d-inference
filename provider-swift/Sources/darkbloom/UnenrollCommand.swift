import ArgumentParser
import Foundation
import ProviderCore

struct Unenroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove the Darkbloom MDM profile and clean up local state.",
        discussion: """
        macOS only allows the user (not an unprivileged binary) to remove
        an MDM profile, so this command opens System Settings → Device
        Management for you and prompts before deleting any local data.
        """
    )

    @Flag(help: "Skip the local-data cleanup confirmation and purge anyway.")
    var force = false

    @Flag(help: "Don't open System Settings.")
    var noOpen = false

    mutating func run() async throws {
        print("Darkbloom Unenrollment")
        print()

        let service = EnrollmentService()
        switch checkMDMEnrollment() {
        case .enrolledDarkbloom:
            print("Darkbloom MDM profile detected. To remove:")
            print("  System Settings → General → Device Management")
            print("  Click on the Darkbloom profile → Remove")
            print()
            if !noOpen {
                print("Opening System Settings...")
                service.openProfilesPaneForRemoval()
            }
        case .enrolledOtherMDM(let serverURL):
            print("This Mac is managed by a different MDM (\(serverURL)) — not Darkbloom's.")
            print("Nothing to remove on the macOS side.")
        case .notEnrolled:
            print("No Darkbloom MDM profile found. Nothing to remove on the macOS side.")
        case .checkFailed:
            print("Couldn't determine MDM state (the profiles tool failed).")
            print("Check System Settings → General → Device Management yourself.")
            if !noOpen {
                print("Opening System Settings...")
                service.openProfilesPaneForRemoval()
            }
        }

        print()
        print("Local data cleanup will remove:")
        print("  • Config dir:    ~/.config/darkbloom/  (and legacy ~/.config/eigeninference/)")
        print("  • Auth token:    ~/.darkbloom/auth_token")
        print("  • Legacy keys:   ~/.darkbloom/{wallet_key,enclave_key.data,…}")
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
