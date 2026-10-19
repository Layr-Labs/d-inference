import ArgumentParser
import DarkbloomFanCore
import DarkbloomFanProtocol
import Foundation
import Testing

@testable import darkbloom

@Suite("Fan status output")
struct FanStatusOutputTests {
    private func helperStatus() -> FanServiceStatus {
        FanServiceStatus(
            enabled: true,
            configuredUID: 501,
            providerActive: true,
            mode: .manual,
            chip: "M4",
            gpuSensorKeys: ["Tg0G", "Tg0H"],
            gpuTemperatureC: 61.3,
            triggerTemperatureC: 45,
            releaseTemperatureC: 40,
            speedPercent: 80,
            fans: [],
            lastError: "sensor stale"
        )
    }

    private func supportedDiagnostic() -> FanDiagnosticReport {
        FanDiagnosticReport(
            chip: "M4",
            supported: true,
            gpuTemperatures: [
                FanTemperatureStatus(key: "Tg0G", celsius: 61.3),
                FanTemperatureStatus(key: "Tg0H", celsius: 59),
            ],
            fans: [
                FanServiceFanStatus(
                    index: 0, actualRPM: 2_500, targetRPM: 4_000,
                    minimumRPM: 1_200, maximumRPM: 5_000, mode: "manual"),
            ],
            error: nil
        )
    }

    @Test("a running helper shows mode, policy, GPU and hardware lines")
    func runningHelperLines() {
        let report = FanStatusReport(
            capability: Fan.packagedCapability,
            installed: true,
            loaded: true,
            helper: helperStatus(),
            helperError: nil,
            diagnostic: supportedDiagnostic()
        )

        #expect(Fan.Status.lines(report) == [
            "Darkbloom fan control (experimental)",
            "Installed: yes",
            "Service: running",
            "Mode: manual",
            "Provider active: yes",
            "Policy: 80.0% at 45.0 C (release below 40.0 C)",
            "GPU: 61.3 C",
            "Last error: sensor stale",
            "Hardware: M4",
            "Compatibility: supported",
            "  Fan 0: actual 2500, target 4000, range 1200-5000, manual",
            "GPU sensors: Tg0G=61.3 C, Tg0H=59.0 C",
        ])
        Fan.Status.print(report)
    }

    @Test("a missing install shows macOS automatic and the enable hint")
    func notInstalledLines() {
        let report = FanStatusReport(
            capability: Fan.packagedCapability,
            installed: false,
            loaded: false,
            helper: nil,
            helperError: nil,
            diagnostic: FanDiagnosticReport(
                chip: "Unknown",
                supported: false,
                gpuTemperatures: [],
                fans: [
                    FanServiceFanStatus(
                        index: 1, actualRPM: nil, targetRPM: nil,
                        minimumRPM: nil, maximumRPM: nil, mode: nil),
                ],
                error: "AppleSMC service was not found"
            )
        )

        #expect(Fan.Status.lines(report) == [
            "Darkbloom fan control (experimental)",
            "Installed: no",
            "Service: stopped",
            "Mode: macOS automatic",
            "Hardware: Unknown",
            "Compatibility: unavailable (AppleSMC service was not found)",
            "  Fan 1: actual n/a, target n/a, range n/a-n/a, unknown",
            "Enable with: sudo darkbloom fan enable",
        ])
    }

    @Test("a loaded helper that does not answer shows the helper error")
    func silentHelperLines() {
        let report = FanStatusReport(
            capability: Fan.packagedCapability,
            installed: true,
            loaded: true,
            helper: nil,
            helperError: "fan helper did not reply within 2 seconds",
            diagnostic: FanDiagnosticReport(
                chip: "M2", supported: false, gpuTemperatures: [], fans: [], error: nil)
        )

        #expect(Fan.Status.lines(report) == [
            "Darkbloom fan control (experimental)",
            "Installed: yes",
            "Service: running",
            "Mode: unknown (helper status unavailable)",
            "Helper error: fan helper did not reply within 2 seconds",
            "Hardware: M2",
            "Compatibility: unsupported",
        ])
    }

    @Test("the JSON report omits a missing helper and keeps the capability")
    func reportJSON() throws {
        let report = FanStatusReport(
            capability: Fan.packagedCapability,
            installed: false,
            loaded: false,
            helper: nil,
            helperError: nil,
            diagnostic: supportedDiagnostic()
        )
        let data = try JSONEncoder().encode(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["capability", "installed", "loaded", "diagnostic"])
        #expect(object["capability"] as? String == "darkbloom-fan-helper-v1")
        let diagnostic = try #require(object["diagnostic"] as? [String: Any])
        #expect(diagnostic["chip"] as? String == "M4")
        let temperatures = try #require(diagnostic["gpuTemperatures"] as? [[String: Any]])
        #expect(temperatures.first?["key"] as? String == "Tg0G")
    }

    @Test("the diagnostic report reads fans and GPU sensors from AppleSMC")
    func diagnosticFromSMC() {
        let smc = FanTestSMC()

        let report = Fan.Status.diagnosticReport(makeBackend: { smc }, brandString: FanServiceFixture.brand)

        #expect(report.chip == "M4")
        #expect(report.supported)
        #expect(report.error == nil)
        #expect(report.gpuTemperatures.map(\.key) == GPUTemperatureCatalog.keys(for: .m4).map(\.rawValue))
        #expect(report.gpuTemperatures.allSatisfy { $0.celsius == 50 })
        #expect(report.fans == [
            FanServiceFanStatus(
                index: 0, actualRPM: 1_500, targetRPM: 1_400,
                minimumRPM: 1_200, maximumRPM: 5_000, mode: "auto"),
            FanServiceFanStatus(
                index: 1, actualRPM: 1_500, targetRPM: 1_400,
                minimumRPM: 1_200, maximumRPM: 5_000, mode: "auto"),
        ])
    }

    @Test("an unknown chip has no validated GPU sensor and is unsupported")
    func diagnosticUnknownChip() {
        let smc = FanTestSMC()

        let report = Fan.Status.diagnosticReport(makeBackend: { smc }, brandString: "Intel Core i9")

        #expect(report.chip == "Unknown")
        #expect(!report.supported)
        #expect(report.gpuTemperatures.isEmpty)
        #expect(report.fans.count == 2)
        #expect(report.error == nil)
    }

    @Test("an AppleSMC failure becomes an unsupported report with the error")
    func diagnosticSMCFailure() {
        let report = Fan.Status.diagnosticReport(
            makeBackend: { throw SMCError.serviceNotFound },
            brandString: FanServiceFixture.brand
        )

        #expect(report.chip == "Unknown")
        #expect(!report.supported)
        #expect(report.fans.isEmpty)
        #expect(report.gpuTemperatures.isEmpty)
        #expect(report.error == "AppleSMC service was not found")
    }
}

@Suite("Fan command arguments")
struct FanCommandArgumentTests {
    @Test("status and diagnose accept --json")
    func jsonFlags() throws {
        let status = try #require(try Darkbloom.parseAsRoot(["fan", "status", "--json"]) as? Fan.Status)
        let diagnose = try #require(try Darkbloom.parseAsRoot(["fan", "diagnose", "--json"]) as? Fan.Diagnose)
        let plain = try #require(try Darkbloom.parseAsRoot(["fan", "diagnose"]) as? Fan.Diagnose)

        #expect(status.json)
        #expect(diagnose.json)
        #expect(!plain.json)
    }

    @Test("enable defaults to 80 percent at 45 C")
    func enableDefaults() throws {
        let enable = try #require(try Darkbloom.parseAsRoot(["fan", "enable"]) as? Fan.Enable)

        #expect(enable.speed == 80)
        #expect(enable.temperature == 45)
    }

    @Test("disable and uninstall parse without options")
    func disableAndUninstall() throws {
        #expect(try Darkbloom.parseAsRoot(["fan", "disable"]) is Fan.Disable)
        #expect(try Darkbloom.parseAsRoot(["fan", "uninstall"]) is Fan.Uninstall)
        #expect(throws: (any Error).self) {
            _ = try Darkbloom.parseAsRoot(["fan", "disable", "--speed", "70"])
        }
    }

    @Test("configure accepts only a temperature")
    func configureTemperatureOnly() throws {
        let configure = try #require(
            try Darkbloom.parseAsRoot(["fan", "configure", "--temperature", "55"]) as? Fan.Configure)

        #expect(configure.speed == nil)
        #expect(configure.temperature == 55)
    }

    @Test("configure without a setting fails validation before any change")
    func configureNeedsASetting() async throws {
        let configure = try #require(try Darkbloom.parseAsRoot(["fan", "configure"]) as? Fan.Configure)

        await #expect(throws: ValidationError.self) {
            var command = configure
            try await command.run()
        }
    }

    @Test("the packaged capability name matches the app marker string")
    func packagedCapability() {
        #expect(Fan.packagedCapability == FanServiceFixture.capabilityMarker)
        #expect(Fan.configuration.commandName == "fan")
    }

    #if DEBUG
    @Test("test-lease rejects durations outside 1 to 300 seconds", arguments: ["0", "301"])
    func testLeaseBounds(seconds: String) async throws {
        let lease = try #require(
            try Darkbloom.parseAsRoot(["fan", "test-lease", "--seconds", seconds]) as? Fan.TestLease)

        await #expect(throws: ValidationError.self) {
            var command = lease
            try await command.run()
        }
    }
    #endif
}
