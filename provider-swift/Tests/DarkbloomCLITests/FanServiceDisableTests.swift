import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

@testable import darkbloom

@Suite("Fan service disable, configure and uninstall")
struct FanServiceDisableTests {
    private static let userUUID = "11111111-2222-3333-4444-555555555555"

    private func enabledConfiguration(_ fixture: FanServiceFixture) throws -> FanServiceConfiguration {
        FanServiceConfiguration(
            enabled: true,
            configuredUID: fixture.uid,
            configuredUserUUID: Self.userUUID,
            policy: try fanPolicy(speed: 75, trigger: 55)
        )
    }

    // MARK: disable

    @Test("disable keeps the stored owner and policy and turns the label off")
    func disableKeepsStoredPolicy() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let stored = try enabledConfiguration(fixture)
        try fixture.writeConfiguration(stored)

        try fixture.manager().disable()

        let configuration = try fixture.readConfiguration()
        #expect(!configuration.enabled)
        #expect(configuration.configuredUID == stored.configuredUID)
        #expect(configuration.configuredUserUUID == Self.userUUID)
        #expect(configuration.policy == stored.policy)
        #expect(fixture.launchd.launchctlVerbs == ["print", "print", "disable"])
        #expect(fixture.launchd.labelEnabled == false)
        #expect(fixture.helper.restoreRequests == 0)
    }

    @Test("disable without a stored policy writes defaults for the sudo user")
    func disableWithoutConfiguration() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }

        try fixture.manager().disable()

        let configuration = try fixture.readConfiguration()
        #expect(!configuration.enabled)
        #expect(configuration.configuredUID == fixture.uid)
        #expect(UUID(uuidString: configuration.configuredUserUUID) != nil)
        #expect(configuration.policy == .defaults)
        #expect(try filePermissions(fixture.paths.configuration.deletingLastPathComponent()) == 0o755)
    }

    @Test("disable without a stored policy needs the sudo user")
    func disableWithoutConfigurationNeedsSudoUser() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }

        let error = fanManagerError { try fixture.manager(environment: [:]).disable() }

        guard case .sudoUserRequired = error else {
            Issue.record("expected sudoUserRequired, got \(String(describing: error))")
            return
        }
        #expect(fixture.launchd.calls.isEmpty)
    }

    @Test("disable requires root")
    func disableRequiresRoot() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager(host: fixture.host(effectiveUserID: 501))

        let error = fanManagerError { try manager.disable() }

        guard case .rootRequired = error else {
            Issue.record("expected rootRequired, got \(String(describing: error))")
            return
        }
    }

    @Test("disable asks a loaded helper for Auto, then boots it out")
    func disableLoadedHelper() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        try fixture.writeConfiguration(try enabledConfiguration(fixture))

        try fixture.manager().disable()

        #expect(fixture.helper.restoreRequests == 1)
        #expect(fixture.launchd.launchctlVerbs == ["print", "print", "bootout", "disable"])
        #expect(!fixture.launchd.loaded)
    }

    @Test("disable restores journaled fans to Auto and removes the journal")
    func disableRecoversJournal() throws {
        let smc = FanTestSMC()
        smc.setUI8(smc.key("F1Md"), 1)
        smc.setUI8("Ftst", 1)
        let fixture = try FanServiceFixture(smc: smc)
        defer { fixture.remove() }
        try fixture.writeJournal(fanIndices: [1], ownsFtst: true)

        try fixture.manager().disable()

        #expect(!fixture.journalExists)
        #expect(try smc.uint8("F1Md") == 0)
        #expect(try smc.uint8("Ftst") == 0)
        #expect(!smc.writes.contains(smc.key("F0Md")))
    }

    @Test("a helper that cannot be booted out restarts disabled and is then stopped")
    func disableBootoutFailureRestartsHelper() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        try fixture.writeConfiguration(try enabledConfiguration(fixture))
        let busy = failed(5, "Boot-out failed: 5: Input/output error")
        fixture.launchd.queue("bootout", busy, busy, busy)

        try fixture.manager().disable()

        #expect(fixture.launchd.launchctlVerbs == [
            "print",
            "print", "bootout", "print", "bootout", "print", "bootout",
            "enable", "print", "kickstart", "print",
            "print", "bootout",
            "disable",
        ])
        let restart = fixture.launchd.calls.first { $0.arguments.first == "kickstart" }
        #expect(restart?.arguments == ["kickstart", "-k", FanServiceManager.target])
        #expect(!fixture.launchd.loaded)
        #expect(fixture.launchd.labelEnabled == false)
    }

    @Test("disable reports when the helper can neither stop nor restart")
    func disableBootoutAndRestartFail() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        let busy = failed(5, "Boot-out failed: 5: Input/output error")
        fixture.launchd.queue("bootout", busy, busy, busy)
        fixture.launchd.queue("kickstart", failed(1, "kickstart refused"))

        let error = fanManagerError { try fixture.manager().disable() }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "could not stop helper (fan launchd operation failed: Boot-out failed: 5: Input/output error) or restart it disabled (fan launchd operation failed: kickstart refused)")
    }

    @Test("disable reports a restarted helper whose journal does not clear")
    func disableBootoutFailureJournalRemains() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        try fixture.writeJournal(fanIndices: [0])
        let busy = failed(5, "Boot-out failed: 5: Input/output error")
        fixture.launchd.queue("bootout", busy, busy, busy)

        let error = fanManagerError { try fixture.manager().disable() }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "helper remains loaded and disabled while retrying automatic restoration")
        #expect(fixture.journalExists)
        #expect(fixture.launchd.loaded)
    }

    @Test("when direct Auto fails, a disabled helper restart repairs the journal")
    func disableRecoveryFailureHelperRepairs() throws {
        let smc = FanTestSMC()
        smc.failWrites(to: smc.key("F0Md"))
        let fixture = try FanServiceFixture(smc: smc)
        defer { fixture.remove() }
        try fixture.writeJournal(fanIndices: [0])
        let journal = fixture.paths.sessionJournal
        fixture.launchd.onCall("kickstart") {
            try? FileManager.default.removeItem(at: journal)
        }

        try fixture.manager().disable()

        #expect(!fixture.journalExists)
        #expect(fixture.launchd.launchctlVerbs == [
            "print", "print",
            "enable", "print", "bootstrap", "kickstart", "print",
            "print", "bootout",
            "disable",
        ])
        #expect(!fixture.launchd.loaded)
    }

    @Test("when direct Auto fails and the journal stays, disable fails")
    func disableRecoveryFailureJournalRemains() throws {
        let smc = FanTestSMC()
        smc.failWrites(to: smc.key("F0Md"))
        let fixture = try FanServiceFixture(smc: smc)
        defer { fixture.remove() }
        try fixture.writeJournal(fanIndices: [0])

        let error = fanManagerError { try fixture.manager().disable() }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "helper remains loaded and disabled while retrying automatic restoration")
        #expect(fixture.launchd.loaded)
        #expect(fixture.launchd.labelEnabled == true)
    }

    @Test("when direct Auto and the helper restart both fail, disable reports both")
    func disableRecoveryAndRestartFail() throws {
        let smc = FanTestSMC()
        smc.failWrites(to: smc.key("F0Md"))
        let fixture = try FanServiceFixture(smc: smc)
        defer { fixture.remove() }
        try fixture.writeJournal(fanIndices: [0])
        fixture.launchd.queue("bootstrap", failed(5, "Bootstrap failed: 5: Input/output error"))

        let error = fanManagerError { try fixture.manager().disable() }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.hasPrefix("direct Auto failed (could not verify automatic fan control: fan ownership recovery failed: "))
        #expect(detail.hasSuffix("recovery helper restart also failed (fan launchd operation failed: Bootstrap failed: 5: Input/output error)"))
    }

    // MARK: configure

    @Test("configure replaces only the policy of a stopped helper")
    func configureStoppedHelper() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let stored = try enabledConfiguration(fixture)
        try fixture.writeConfiguration(stored)
        let updated = try fanPolicy(speed: 90, trigger: 60)

        try fixture.manager().configure(policy: updated)

        let configuration = try fixture.readConfiguration()
        #expect(configuration.enabled)
        #expect(configuration.configuredUID == stored.configuredUID)
        #expect(configuration.configuredUserUUID == Self.userUUID)
        #expect(configuration.policy == updated)
        #expect(try fixture.manager().configuration() == configuration)
        #expect(fixture.launchd.launchctlVerbs == ["print"])
    }

    @Test("configure restarts a running helper so it reads the new policy")
    func configureRunningHelper() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        try fixture.writeConfiguration(try enabledConfiguration(fixture))

        try fixture.manager().configure(policy: .defaults)

        let restart = fixture.launchd.calls.last
        #expect(restart?.arguments == ["kickstart", "-k", "system/io.darkbloom.fan"])
        #expect(try fixture.readConfiguration().policy == .defaults)
    }

    @Test("configure reports a failed helper restart")
    func configureRestartFails() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        try fixture.writeConfiguration(try enabledConfiguration(fixture))
        fixture.launchd.queue("kickstart", failed(1, "Could not kickstart service"))

        let error = fanManagerError { try fixture.manager().configure(policy: .defaults) }

        guard case .launchctlFailed(let detail) = error else {
            Issue.record("expected launchctlFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "Could not kickstart service")
    }

    @Test("configure needs an installed policy and root")
    func configureNeedsPolicyAndRoot() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }

        #expect(throws: FanDurableFileError.self) {
            try fixture.manager().configure(policy: .defaults)
        }
        let notRoot = fixture.manager(host: fixture.host(effectiveUserID: 501))
        let error = fanManagerError { try notRoot.configure(policy: .defaults) }
        guard case .rootRequired = error else {
            Issue.record("expected rootRequired, got \(String(describing: error))")
            return
        }
        #expect(fixture.launchd.calls.isEmpty)
    }

    // MARK: uninstall and state

    @Test("uninstall disables, then removes the helper, plist and policy")
    func uninstallRemovesFiles() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.helper.answer(fixture.matchingStatus())
        let manager = fixture.manager()
        _ = try manager.enable(policy: .defaults)
        #expect(manager.isInstalled())

        try manager.uninstall()

        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: fixture.paths.helper.path))
        #expect(!fileManager.fileExists(atPath: fixture.paths.launchDaemonPlist.path))
        #expect(!fileManager.fileExists(atPath: fixture.paths.configuration.path))
        #expect(!manager.isInstalled())
        #expect(fixture.launchd.labelEnabled == false)
        #expect(!fixture.launchd.loaded)
    }

    @Test("uninstall keeps recovery material while a journal remains")
    func uninstallKeepsFilesWithJournal() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.helper.answer(fixture.matchingStatus())
        let manager = fixture.manager()
        _ = try manager.enable(policy: .defaults)
        fixture.launchd.onCall("disable") {
            try? fixture.writeJournal(fanIndices: [0])
        }

        let error = fanManagerError { try manager.uninstall() }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "ownership journal remains after restore; refusing to remove recovery material")
        #expect(manager.isInstalled())
        #expect(FileManager.default.fileExists(atPath: fixture.paths.configuration.path))
    }

    @Test("installed means both the helper and the LaunchDaemon plist exist")
    func isInstalledNeedsBothFiles() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        #expect(!manager.isInstalled())

        try FileManager.default.createDirectory(
            at: fixture.paths.helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fixture.paths.helper)
        #expect(!manager.isInstalled())

        try manager.writeLaunchDaemonPlist()
        #expect(manager.isInstalled())
    }

    @Test("loaded state follows launchctl print with a 5 second limit")
    func isLoadedUsesLaunchctlPrint() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }

        #expect(fixture.manager().isLoaded())
        let call = try #require(fixture.launchd.calls.first)
        #expect(call.executable == "/bin/launchctl")
        #expect(call.arguments == ["print", "system/io.darkbloom.fan"])
        #expect(call.timeout == 5)
    }
}
