import ArgumentParser
import Foundation
import ProviderCore

struct Enroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Enroll this Mac in Darkbloom MDM (device-attestation profile).",
        discussion: """
        Requests a per-device .mobileconfig profile from the coordinator,
        opens it (registering with System Settings), then opens the
        Profiles pane so you can click Install. The profile lets the
        coordinator verify that SIP/Secure Boot are on and that the
        Secure Enclave is genuine Apple hardware.

        Darkbloom CANNOT erase, lock, or remotely control your Mac.
        Remove anytime in System Settings → Device Management.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Override coordinator URL (HTTPS).")
    var coordinator: String?

    @Flag(help: "Don't open System Settings; just download the profile.")
    var noOpen = false

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let coordinatorURL = coordinator
            ?? snapshot.config.coordinator.url
        let httpBase = coordinatorHTTPBase(coordinatorURL)

        print("Darkbloom Device Attestation Enrollment")
        print("Coordinator: \(httpBase)")
        print()

        let service = EnrollmentService()
        let result: EnrollmentResult
        do {
            result = try await service.enroll(
                coordinatorURL: coordinatorURL,
                openSystemSettings: !noOpen
            )
        } catch let err as EnrollmentError {
            printError("\(err)")
            throw ExitCode.failure
        }

        if result.alreadyEnrolled {
            print("  ✓ Already enrolled — no action needed.")
            print("  Verify with: darkbloom doctor")
            return
        }

        print("  → Device serial:  \(result.serialNumber)")
        print("  → Profile saved:  \(result.profilePath.path)")
        print()

        if noOpen {
            print("  Install the profile manually:")
            print("    open \(result.profilePath.path)")
            print()
        } else {
            print("  System Settings → Device Management is now open.")
            print("  Click Install on the Darkbloom profile and enter your password.")
            print()
            print("  This verifies:")
            print("    • SIP, Secure Boot, and system integrity")
            print("    • Your Secure Enclave is genuine Apple hardware")
            print("    • Device identity signed by Apple's Root CA")
            print()
            print("  Darkbloom CANNOT erase, lock, or control your Mac.")
        }

        print("After installing, verify with: darkbloom doctor")
    }
}
