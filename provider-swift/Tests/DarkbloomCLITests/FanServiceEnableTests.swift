import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

@testable import darkbloom

@Suite("Fan service enable")
struct FanServiceEnableTests {
    @Test("enable installs the helper, policy and LaunchDaemon, then starts the job")
    func enableInstallsAndStarts() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.helper.answer(fixture.matchingStatus())
        let policy = try fanPolicy(speed: 70, trigger: 50)

        let status = try fixture.manager().enable(policy: policy)

        #expect(status == fixture.matchingStatus().withUpdatedAt(status.updatedAt))
        let installed = try Data(contentsOf: fixture.paths.helper)
        #expect(installed == (try Data(contentsOf: fixture.bundledHelper)))
        #expect(try filePermissions(fixture.paths.helper) == 0o755)

        let configuration = try fixture.readConfiguration()
        #expect(configuration.enabled)
        #expect(configuration.configuredUID == fixture.uid)
        #expect(UUID(uuidString: configuration.configuredUserUUID) != nil)
        #expect(configuration.policy == policy)
        #expect(try filePermissions(fixture.paths.configuration) == 0o600)

        let plistData = try Data(contentsOf: fixture.paths.launchDaemonPlist)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        #expect(plist["Label"] as? String == FanIPC.machServiceName)
        #expect(plist["ProgramArguments"] as? [String] == [fixture.paths.helper.path])
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(try filePermissions(fixture.paths.launchDaemonPlist) == 0o644)

        #expect(fixture.launchd.launchctlVerbs == ["print", "enable", "bootstrap", "kickstart"])
        let bootstrap = fixture.launchd.calls.first { $0.arguments.first == "bootstrap" }
        #expect(bootstrap?.arguments == ["bootstrap", "system", fixture.paths.launchDaemonPlist.path])
        #expect(fixture.launchd.labelEnabled == true)
        #expect(fixture.launchd.loaded)
        #expect(fixture.helper.restoreRequests == 1)

        let codesign = fixture.launchd.codesignCalls
        #expect(codesign.count == 7)
        #expect(codesign.first?.contains("--deep") == true)
        #expect(codesign.first?.last == fixture.app.path)
        #expect(codesign.last?.last == fixture.paths.helper.path)
        #expect(codesign.allSatisfy { $0.contains { $0.hasPrefix("-R=") } })

        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.helper.deletingLastPathComponent().path)
        #expect(leftovers == [fixture.paths.helper.lastPathComponent])
        #expect(fixture.manager().isInstalled())
    }

    @Test("enable boots out a loaded helper before it installs")
    func enableBootsOutLoadedHelper() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        fixture.helper.answer(fixture.matchingStatus())

        _ = try fixture.manager().enable(policy: .defaults)

        #expect(fixture.launchd.launchctlVerbs == ["print", "bootout", "enable", "bootstrap", "kickstart"])
    }

    @Test("enable requires root")
    func enableRequiresRoot() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager(host: fixture.host(effectiveUserID: 501))

        let error = fanManagerError { _ = try manager.enable(policy: .defaults) }

        guard case .rootRequired = error else {
            Issue.record("expected rootRequired, got \(String(describing: error))")
            return
        }
        #expect(fixture.launchd.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.configuration.path))
    }

    @Test("enable requires the sudo user")
    func enableRequiresSudoUser() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }

        let missing = fanManagerError {
            _ = try fixture.manager(environment: [:]).enable(policy: .defaults)
        }
        let empty = fanManagerError {
            _ = try fixture.manager(environment: ["SUDO_UID": ""]).enable(policy: .defaults)
        }

        guard case .sudoUserRequired = missing, case .sudoUserRequired = empty else {
            Issue.record("expected sudoUserRequired, got \(String(describing: missing)) and \(String(describing: empty))")
            return
        }
    }

    @Test("enable rejects root, text and unknown invoking UIDs", arguments: ["0", "abc", "4000000000"])
    func enableRejectsInvalidUID(raw: String) throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }

        let error = fanManagerError {
            _ = try fixture.manager(sudoUID: raw).enable(policy: .defaults)
        }

        guard case .invalidInvokingUID(let value) = error else {
            Issue.record("expected invalidInvokingUID, got \(String(describing: error))")
            return
        }
        #expect(value == raw)
    }

    @Test("enable stops when AppleSMC is unavailable")
    func enableNeedsSMC() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager(host: fixture.host(smcAvailable: false))

        #expect(throws: SMCError.serviceNotFound) {
            _ = try manager.enable(policy: .defaults)
        }
        #expect(fixture.launchd.calls.isEmpty)
    }

    @Test("enable refuses a CLI that is not inside Darkbloom.app")
    func enableNeedsBundledHelper() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let loose = fixture.root.appendingPathComponent("bin/darkbloom")
        let manager = fixture.manager(host: fixture.host(executableURL: loose))

        let error = fanManagerError { _ = try manager.enable(policy: .defaults) }

        guard case .helperNotBundled(let searched) = error else {
            Issue.record("expected helperNotBundled, got \(String(describing: error))")
            return
        }
        #expect(searched == ["a signed Darkbloom.app/Contents/Helpers installation"])
        #expect(fixture.helper.restoreRequests == 0)
    }

    @Test("enable fails closed when the helper signature is rejected")
    func enableRejectsHelperSignature() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.launchd.queue(
            "codesign",
            FanProcessResult(status: 0, output: ""),
            FanProcessResult(status: 0, output: ""),
            failed(1, "code object is not signed at all")
        )

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .signatureFailed(let detail) = error else {
            Issue.record("expected signatureFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "code object is not signed at all")
        #expect(fixture.launchd.launchctlVerbs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.helper.path))
    }

    @Test("a hardware refusal disables the policy and rethrows the cause")
    func enableUnsupportedHardwareDisables() throws {
        let smc = FanTestSMC()
        smc.setUI8(smc.key("F1Md"), 1)
        let fixture = try FanServiceFixture(smc: smc)
        defer { fixture.remove() }

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .unsupported(let detail) = error else {
            Issue.record("expected unsupported, got \(String(describing: error))")
            return
        }
        #expect(detail == "another application manually controls fans [1]")
        let configuration = try fixture.readConfiguration()
        #expect(!configuration.enabled)
        #expect(configuration.configuredUID == fixture.uid)
        #expect(fixture.launchd.launchctlVerbs == ["print", "print", "disable"])
        #expect(fixture.launchd.labelEnabled == false)
        #expect(fixture.helper.restoreRequests == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.helper.path))
    }

    @Test("enable refuses Macs without fans, GPU sensors or a free Ftst gate")
    func enableHardwarePreflight() throws {
        let noFans = FanTestSMC(fanCount: 0)
        let noSensors = FanTestSMC(gpuCelsius: 0)
        let heldGate = FanTestSMC()
        heldGate.setUI8("Ftst", 1)
        let cases: [(FanTestSMC, String)] = [
            (noFans, "this Mac reports no fans"),
            (noSensors, "no validated GPU temperature sensor was found for M4"),
            (heldGate, "another application holds the Ftst fan-control gate"),
        ]
        for (smc, expected) in cases {
            let fixture = try FanServiceFixture(smc: smc)
            defer { fixture.remove() }

            let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

            guard case .unsupported(let detail) = error else {
                Issue.record("expected unsupported, got \(String(describing: error))")
                continue
            }
            #expect(detail == expected)
            #expect(try fixture.readConfiguration().enabled == false)
        }
    }

    @Test("a helper status for another policy fails the enable")
    func enableRejectsMismatchedStatus() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.helper.answer(fixture.matchingStatus(enabled: false))

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .launchctlFailed(let detail) = error else {
            Issue.record("expected launchctlFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "helper status does not match the installed policy")
        #expect(try fixture.readConfiguration().enabled == false)
        #expect(Array(fixture.launchd.launchctlVerbs.suffix(3)) == ["print", "bootout", "disable"])
        #expect(!fixture.launchd.loaded)
    }

    @Test("a helper that never answers fails the enable after 30 polls")
    func enableTimesOutWithoutStatus() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .launchctlFailed(let detail) = error else {
            Issue.record("expected launchctlFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "helper started but did not answer status")
        #expect(fixture.helper.statusRequests == 30)
        #expect(fixture.launchd.labelEnabled == false)
    }

    @Test("enable reports when the failed helper cannot be stopped")
    func enableCleanupBootoutFails() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.launchd.queue("bootout", failed(5, "Boot-out failed: 5: Input/output error"))

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.hasPrefix("enable failed (fan launchd operation failed: helper started but did not answer status)"))
        #expect(detail.hasSuffix("helper could not be stopped safely (fan launchd operation failed: Boot-out failed: 5: Input/output error)"))
        #expect(try fixture.readConfiguration().enabled)
    }

    @Test("enable reports when the label cannot be disabled after a failure")
    func enableCleanupDisableFails() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.launchd.queue("disable", failed(1, "Not privileged"))

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "enable failed (fan launchd operation failed: helper started but did not answer status); disabling failed (fan launchd operation failed: Not privileged)")
    }

    @Test("a stranded journal keeps a restarted helper retrying Auto")
    func enableJournalFailureRestartsHelper() throws {
        let smc = FanTestSMC()
        smc.failWrites(to: smc.key("F0Md"))
        let fixture = try FanServiceFixture(smc: smc)
        defer { fixture.remove() }
        try fixture.writeJournal(fanIndices: [0])

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.hasSuffix("helper was restarted to keep retrying Auto"))
        #expect(detail.contains("cleanup failed (could not verify automatic fan control: fan ownership recovery failed: restoreMode fan 0: "))
        #expect(fixture.journalExists)
        #expect(Array(fixture.launchd.launchctlVerbs.suffix(4)) == ["enable", "bootstrap", "kickstart", "print"])
        #expect(fixture.launchd.loaded)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.helper.path))
    }

    @Test("when the helper cannot restart, enable retries Auto directly 20 times")
    func enableJournalFailureDirectRetriesFail() throws {
        let smc = FanTestSMC()
        smc.failWrites(to: smc.key("F0Md"))
        let fixture = try FanServiceFixture(smc: smc)
        defer { fixture.remove() }
        try fixture.writeJournal(fanIndices: [0])
        fixture.launchd.queue("bootstrap", failed(5, "Bootstrap failed: 5: Input/output error"))

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("helper restart failed (fan launchd operation failed: Bootstrap failed: 5: Input/output error)"))
        #expect(detail.contains("direct Auto retries failed"))
        // One write at preflight, one in cleanup, then 20 direct retries.
        #expect(smc.writes.filter { $0 == smc.key("F0Md") }.count == 22)
        #expect(fixture.journalExists)
    }

    @Test("a direct Auto retry that succeeds lets enable disable cleanly")
    func enableJournalFailureDirectRetrySucceeds() throws {
        let smc = FanTestSMC()
        smc.setUI8(smc.key("F0Md"), 1)
        smc.failWrites(to: smc.key("F0Md"), count: 2)
        let fixture = try FanServiceFixture(smc: smc)
        defer { fixture.remove() }
        try fixture.writeJournal(fanIndices: [0])
        fixture.launchd.bootstrapLoads = false

        let error = fanManagerError { _ = try fixture.manager().enable(policy: .defaults) }

        guard case .restoreFailed(let detail) = error else {
            Issue.record("expected restoreFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.hasPrefix("fan ownership recovery failed"))
        #expect(!fixture.journalExists)
        #expect(try smc.uint8("F0Md") == 0)
        #expect(try fixture.readConfiguration().enabled == false)
        #expect(fixture.launchd.labelEnabled == false)
    }
}

extension FanServiceStatus {
    func withUpdatedAt(_ date: Date) -> FanServiceStatus {
        FanServiceStatus(
            helperVersion: helperVersion,
            protocolVersion: protocolVersion,
            enabled: enabled,
            configuredUID: configuredUID,
            providerActive: providerActive,
            mode: mode,
            chip: chip,
            gpuSensorKeys: gpuSensorKeys,
            gpuTemperatureC: gpuTemperatureC,
            triggerTemperatureC: triggerTemperatureC,
            releaseTemperatureC: releaseTemperatureC,
            speedPercent: speedPercent,
            fans: fans,
            lastError: lastError,
            updatedAt: date
        )
    }
}
