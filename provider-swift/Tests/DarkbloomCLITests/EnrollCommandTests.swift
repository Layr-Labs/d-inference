import ArgumentParser
import ProviderCore
import Testing
@testable import darkbloom

@Suite struct EnrollCommandTests {
    @Test func helpSaysAppAttestOnlyAndMDMRetired() {
        let help = Enroll.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("App Attest only"))
        #expect(help.contains("macOS 27 or later"))
        #expect(help.contains("Darkbloom MDM is retired"))
        #expect(help.contains("downloads no profile"))
        #expect(help.contains("unenroll (choose 2)"))
        #expect(!help.contains("grandfathered"))
        #expect(!help.contains(".mobileconfig"))
    }

    /// `enroll` is a retired command: it still runs (older scripts and the
    /// served installer name it) but is not offered in the top-level help.
    @Test func enrollIsHiddenFromTheTopLevelHelp() {
        #expect(!Enroll.configuration.shouldDisplay)
        let help = Darkbloom.helpMessage()
        #expect(!help.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("enroll ") })
        #expect(help.contains("unenroll"))
    }

    @Test func macOS27GetsAppAttestSetupAndNoDownload() {
        let lines = Enroll.guidance(macOSMajorVersion: 27, profileNotice: nil)
        #expect(lines.contains("  \(ProviderOnboardingPolicy.appAttestRequirement)"))
        #expect(lines.contains("  \(ProviderOnboardingPolicy.appAttestGuidance)"))
        #expect(!lines.contains { $0.contains("Profile saved") || $0.contains("Install") })
    }

    @Test func olderMacOSIsToldToUpgradeInsteadOfEnrolling() {
        let lines = Enroll.guidance(macOSMajorVersion: 26, profileNotice: nil)
        #expect(lines.contains { $0.contains("macOS 26 and cannot serve") && $0.contains("macOS 27 or later") })
        #expect(!lines.contains("  \(ProviderOnboardingPolicy.appAttestGuidance)"))
    }

    @Test func anInstalledRetiredProfileIsNamedForRemoval() {
        let notice = RetiredMDMProfile.notice(for: .enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect"))
        let lines = Enroll.guidance(macOSMajorVersion: 27, profileNotice: notice)
        #expect(lines.last == "  \(notice ?? "")")
    }
}
