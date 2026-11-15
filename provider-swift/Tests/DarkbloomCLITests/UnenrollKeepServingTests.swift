import ArgumentParser
@testable import ProviderCore
import Testing
@testable import darkbloom

@Suite struct UnenrollKeepServingTests {
    @Test func profileRemovalIsAnExplicitSeparateCommandMode() throws {
        let command = try #require(try Darkbloom.parseAsRoot([
            "unenroll", "--keep-serving", "--no-open", "--config", "/tmp/provider.toml"
        ]) as? Unenroll)
        #expect(command.keepServing)
        #expect(command.noOpen)
        #expect(!command.force)
        #expect(command.configOptions.config == "/tmp/provider.toml")
        let legacy = try #require(try Darkbloom.parseAsRoot(["unenroll", "--force"]) as? Unenroll)
        #expect(!legacy.keepServing)
    }

    @Test func profileRemovalCannotInvokeForcedCleanup() throws {
        let command = try #require(try Darkbloom.parseAsRoot(["unenroll", "--keep-serving", "--force"]) as? Unenroll)
        #expect(throws: ValidationError.self) { try command.guideRetiredProfileRemoval() }
    }

    private struct Run {
        var lines: [String] = []
        var errors: [String] = []
        var opened = 0
        var identified = 0
    }

    private func guide(_ enrollment: MDMEnrollmentState, target: DarkbloomMDMRemovalTarget? = nil,
                       open: Bool = true, macOS: Int = 27) throws -> Run {
        var run = Run()
        try Unenroll.guideRetiredProfileRemoval(
            enrollment: enrollment,
            identifyProfile: { run.identified += 1; return target },
            openSettings: open ? { run.opened += 1 } : nil,
            macOSMajorVersion: macOS,
            writeLine: { run.lines.append($0) }, writeError: { run.errors.append($0) })
        return run
    }

    private let ours = MDMEnrollmentState.enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect")

    /// The old gate (current App Attest lease + the coordinator's
    /// `mdm_removal_ready`) is gone: an installed Darkbloom profile is named and
    /// System Settings opens with no daemon state at all.
    @Test func installedProfileIsNamedAndSettingsOpenWithoutAnyReadinessGate() throws {
        let target = DarkbloomMDMRemovalTarget(
            identifier: DarkbloomMDMRemoval.profileIdentifier, displayName: "Darkbloom Provider Enrollment",
            serverURL: "https://api.darkbloom.dev/mdm/connect")
        let run = try guide(ours, target: target)
        #expect(run.errors.isEmpty)
        #expect(run.opened == 1)
        #expect(run.lines.contains("  Darkbloom Provider Enrollment"))
        #expect(run.lines.contains("  Identifier: io.darkbloom.enroll"))
        #expect(run.lines.contains("  Server: https://api.darkbloom.dev/mdm/connect"))
        #expect(run.lines.contains { $0.contains("Keep any profile from your employer or school") })
        #expect(run.lines.contains { $0.contains("the provider keeps running") })
        #expect(!run.lines.contains { $0.contains("macOS 27 or later to serve") })
    }

    @Test func anUnreadableProfileListFallsBackToTheEnrollmentServer() throws {
        let run = try guide(ours, target: nil)
        #expect(run.opened == 1)
        #expect(run.lines.contains("  the profile named \"Darkbloom Provider Enrollment\" (server https://api.darkbloom.dev/mdm/connect)"))
    }

    @Test func olderMacOSIsAlsoToldToUpgradeToKeepServing() throws {
        let run = try guide(ours, macOS: 26)
        #expect(run.opened == 1)
        #expect(run.lines.contains { $0.contains("needs macOS 27 or later to serve") })
    }

    @Test func noOpenNamesTheProfileWithoutOpeningSettings() throws {
        let run = try guide(ours, open: false)
        #expect(run.opened == 0)
        #expect(run.lines.contains { $0.contains("remove only:") })
    }

    @Test func nothingIsOpenedOrOfferedForAnyOtherProfile() throws {
        for state: MDMEnrollmentState in [
            .notEnrolled,
            .enrolledOtherMDM(serverURL: "https://corp.example/mdm/connect"),
        ] {
            let run = try guide(state)
            #expect(run.opened == 0, "\(state)")
            #expect(run.identified == 0, "\(state)")
            #expect(run.errors.isEmpty, "\(state)")
            #expect(!run.lines.contains { $0.contains("remove only:") }, "\(state)")
        }
        #expect(try guide(.notEnrolled).lines == ["No Darkbloom MDM profile is installed; nothing to remove."])
        #expect(try guide(.enrolledOtherMDM(serverURL: "https://corp.example/mdm/connect")).lines
            == ["This Mac's management profile is not Darkbloom's. Keep your organization's profile installed."])
    }

    @Test func anUnknownEnrollmentStateFailsWithoutOpeningAnything() {
        var run = Run()
        #expect(throws: ExitCode.self) {
            try Unenroll.guideRetiredProfileRemoval(
                enrollment: .checkFailed,
                identifyProfile: { run.identified += 1; return nil },
                openSettings: { run.opened += 1 },
                writeLine: { run.lines.append($0) }, writeError: { run.errors.append($0) })
        }
        #expect(run.opened == 0)
        #expect(run.identified == 0)
        #expect(run.errors.count == 1)
    }
}
