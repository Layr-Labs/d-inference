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
    }

    private func guide(_ enrollment: MDMEnrollmentState, open: Bool = true, macOS: Int = 27) throws -> Run {
        var run = Run()
        try Unenroll.guideRetiredProfileRemoval(
            enrollment: enrollment,
            openSettings: open ? { run.opened += 1 } : nil,
            macOSMajorVersion: macOS,
            writeLine: { run.lines.append($0) }, writeError: { run.errors.append($0) })
        return run
    }

    private let ours = MDMEnrollmentState.enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect")

    /// No readiness gate and no privileges: an installed Darkbloom profile is
    /// named by its display name and the server `profiles status` reports, and
    /// System Settings opens, with no daemon state and no administrator read.
    @Test func installedProfileIsNamedAndSettingsOpenWithoutAnyGateOrPrivilege() throws {
        let run = try guide(ours)
        #expect(run.errors.isEmpty)
        #expect(run.opened == 1)
        #expect(run.lines == [
            "Darkbloom no longer uses its MDM profile: Macs are verified with App Attest.",
            "In System Settings → General → Device Management, remove only:",
            "  the profile named \"Darkbloom Provider Enrollment\" (server https://api.darkbloom.dev/mdm/connect)",
            "If no profile has exactly this name, remove nothing.",
            "Keep any profile from your employer or school.",
            "Your Darkbloom account, machine identity, App Attest keys, and model data are kept; the provider keeps running.",
        ])
        #expect(!run.lines.contains { $0.contains("Administrator") || $0.contains("Identifier:") })
    }

    /// The other build environment's Darkbloom profile belongs to that install:
    /// it is named as such and never offered here.
    @Test func theOtherInstallsProfileIsNeverOffered() throws {
        let other = BuildEnvironment.allCases.first { $0 != .current }!
        let state = parseMDMEnrollmentStatus(
            "MDM enrollment: Yes\nMDM server: \(other.coordinatorHTTPURL)/mdm/connect\n")
        #expect(state.otherInstall == other)
        let run = try guide(state)
        #expect(run.opened == 0)
        #expect(run.lines.count == 1)
        #expect(run.lines[0].contains("this install does not remove it"))
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
                openSettings: { run.opened += 1 },
                writeLine: { run.lines.append($0) }, writeError: { run.errors.append($0) })
        }
        #expect(run.opened == 0)
        #expect(run.errors.count == 1)
    }
}
