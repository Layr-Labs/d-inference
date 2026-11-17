import ArgumentParser
import Foundation
import ProviderCore

struct Enroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain verification setup: App Attest only, on macOS 27 or later.",
        discussion: """
        Darkbloom verifies Macs with App Attest only, which needs macOS 27 or later.
        Darkbloom MDM is retired: this command downloads no profile and changes nothing.
        Link your account, start the provider and check \(BuildEnvironment.current.cliName) status;
        serving starts once the coordinator authorizes the connection with App Attest.
        An old Darkbloom MDM profile is no longer used; remove it with
        \(BuildEnvironment.current.cliName) unenroll (choose 2).
        """,
        // Retired with Darkbloom MDM: still runs for older scripts and the
        // served installer, which name it, but is not offered in help.
        shouldDisplay: false
    )

    // Accepted so older scripts keep working; enroll reads no config, contacts
    // no coordinator and opens nothing any more.
    @OptionGroup(visibility: .hidden) var configOptions: ConfigOptions

    @Option(help: .hidden)
    var coordinator: String?

    @Flag(help: .hidden)
    var noOpen = false

    mutating func run() async throws {
        let macOSMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let lines = Self.guidance(
            macOSMajorVersion: macOSMajorVersion,
            profileNotice: RetiredMDMProfile.notice(for: checkMDMEnrollment()))
        for line in lines { print(line) }
        if !ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion) {
            throw ExitCode.failure
        }
    }

    static func guidance(macOSMajorVersion: Int, profileNotice: String?) -> [String] {
        var lines = ["Darkbloom device verification", "", "  \(ProviderOnboardingPolicy.appAttestRequirement)"]
        if ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion) {
            lines.append("  \(ProviderOnboardingPolicy.appAttestGuidance)")
        } else {
            lines.append("  This Mac runs macOS \(macOSMajorVersion) and cannot serve. \(ProviderOnboardingPolicy.upgradeGuidance)")
        }
        if let profileNotice { lines.append("  \(profileNotice)") }
        return lines
    }
}
