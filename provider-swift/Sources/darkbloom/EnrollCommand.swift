import ArgumentParser
import Foundation
import ProviderCore

struct Enroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check enrollment eligibility: new providers require macOS 27+ App Attest.",
        discussion: """
        New providers require macOS 27 or later and coordinator-qualified App Attest.
        The OS version alone does not establish eligibility.
        On macOS 27 or later, use App Attest without downloading an MDM profile.
        Link your account, start the provider and check darkbloom status for
        coordinator approval. Existing management profiles are kept in place.

        Darkbloom MDM will be deactivated soon. Upgrade to macOS 27 or later
        to avoid Darkbloom MDM enrollment.

        Only grandfathered account/key pairs can temporarily serve using legacy MDM.
        MDM-only providers receive no base rewards; these require current qualified App Attest authorization.
        On older macOS, checks eligibility with the coordinator, even if a
        Darkbloom profile is already installed. For an eligible machine without
        that profile, requests a .mobileconfig profile from the coordinator,
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

    @Flag(help: "Check eligibility and download a needed profile without opening System Settings.")
    var noOpen = false

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let coordinatorURL = coordinator
            ?? snapshot.config.coordinator.url
        let httpBase = coordinatorHTTPBase(coordinatorURL)

        print("Darkbloom Device Attestation Enrollment")
        print("Coordinator: \(httpBase)")
        print()
        print("  \(ProviderOnboardingPolicy.retirementNotice)")
        print("  \(Self.eligibilityNotice)")
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

        guard case .mdm(let profilePath, let alreadyEnrolled) = result else {
            print("  \(ProviderOnboardingPolicy.appAttestGuidance)")
            return
        }

        if alreadyEnrolled {
            print("  Legacy eligibility confirmed; already enrolled. No profile installation needed.")
            print("  Verify current serving authorization with: darkbloom status")
            return
        }

        print("  → Profile saved:  \(profilePath.path)")
        print()

        if noOpen {
            print("  Install the profile manually:")
            print("    open \(profilePath.path)")
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

    static let eligibilityNotice =
        "New providers require macOS 27 or later and coordinator-qualified App Attest. "
        + "Check App Attest qualification with `darkbloom status`; the OS version alone is not approval. "
        + "Grandfathered MDM machines may serve temporarily, but MDM-only providers receive no base rewards. "
        + "Base rewards require current qualified App Attest authorization."
}
