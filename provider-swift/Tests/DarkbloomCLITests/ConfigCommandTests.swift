import ArgumentParser
import Foundation
import ProviderCore
import Testing
@testable import darkbloom

// `darkbloom config get|set schedule` grammar + TOML round-trip. Everything
// here runs against temp config fixtures via explicit --config paths — never
// the operator's real provider.toml.
@Suite("config get|set schedule")
struct ConfigCommandTests {
    private func tmpConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-config-\(UUID().uuidString).toml")
    }

    private func writeConfig(_ toml: String, to url: URL) throws {
        try toml.write(to: url, atomically: true, encoding: .utf8)
    }

    private let baseTOML = """
    [provider]
    name = "testprovider"
    auto_update = false
    auto_restart = true

    [coordinator]
    url = "wss://example.test/ws/provider"
    heartbeat_interval_secs = 7

    [backend]
    port = 8100
    model = "gemma-4-26b-qat-4bit"
    idle_timeout_mins = 45
    max_model_slots = 2

    [schedule]
    enabled = true

    [[schedule.windows]]
    days = ["mon", "tue"]
    start = "20:00"
    end = "07:00"
    """

    // MARK: Grammar

    @Test("always/off parse to the disable plan")
    func parseAlways() throws {
        #expect(try ScheduleSetPlan.parse(["always"]) == .always)
        #expect(try ScheduleSetPlan.parse(["off"]) == .always)
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["always", "extra"]) }
    }

    @Test("idle-timeout-minutes parses a non-negative integer")
    func parseIdleTimeout() throws {
        #expect(try ScheduleSetPlan.parse(["idle-timeout-minutes", "90"]) == .idleTimeoutMinutes(90))
        #expect(try ScheduleSetPlan.parse(["idle-timeout-minutes", "0"]) == .idleTimeoutMinutes(0))
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["idle-timeout-minutes", "soon"]) }
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["idle-timeout-minutes"]) }
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["idle-timeout-minutes", "-5"]) }
    }

    @Test("window grammar: aliases, day lists, overnight wrap")
    func parseWindows() throws {
        let plan = try ScheduleSetPlan.parse(["weekdays", "20:00-07:00"])
        guard case .windows(let windows) = plan else {
            Issue.record("expected .windows, got \(plan)")
            return
        }
        #expect(windows.count == 1)
        #expect(windows[0].days == ["mon", "tue", "wed", "thu", "fri"])
        #expect(windows[0].start == "20:00")
        #expect(windows[0].end == "07:00")

        guard case .windows(let weekend) = try ScheduleSetPlan.parse(["weekend", "09:00-18:00"]),
              case .windows(let daily) = try ScheduleSetPlan.parse(["daily", "00:00-23:59"]),
              case .windows(let listed) = try ScheduleSetPlan.parse(["mon,friday,sun", "12:30-13:45"])
        else {
            Issue.record("expected .windows for aliases")
            return
        }
        #expect(weekend[0].days == ["sat", "sun"])
        #expect(daily[0].days == ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        #expect(listed[0].days == ["mon", "fri", "sun"])

        // Multiple windows are flat pairs; odd arity is a usage error.
        guard case .windows(let two) = try ScheduleSetPlan.parse(
            ["weekdays", "20:00-07:00", "sat,sun", "09:00-18:00"])
        else {
            Issue.record("expected .windows for two windows")
            return
        }
        #expect(two.count == 2)
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["weekdays", "20:00-07:00", "sat"]) }
    }

    @Test("invalid days, times, and same-endpoint windows reject")
    func parseRejects() {
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["noday", "10:00-11:00"]) }
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["mon", "25:00-11:00"]) }
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["mon", "10:00"]) }
        // Equal endpoints silently degrade Schedule.from(config:) to nil
        // ("always available") server-side — reject loudly instead.
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse(["mon", "10:00-10:00"]) }
        #expect(throws: (any Error).self) { try ScheduleSetPlan.parse([]) }
    }

    // MARK: Read path

    @Test("get emits the [schedule] section plus idle_timeout_minutes")
    func getSchedulePayload() throws {
        let url = tmpConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeConfig(baseTOML, to: url)

        let output = try loadScheduleAvailability(configPath: url.path)
        #expect(output.enabled == true)
        #expect(output.windows == [ScheduleWindowOutput(days: ["mon", "tue"], start: "20:00", end: "07:00")])
        #expect(output.idleTimeoutMinutes == 45)
    }

    @Test("get on a schedule-free config reports disabled with defaults")
    func getScheduleDefaults() throws {
        let url = tmpConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeConfig("[provider]\nname = \"t\"\n", to: url)

        let output = try loadScheduleAvailability(configPath: url.path)
        #expect(output.enabled == false)
        #expect(output.windows == [])
        #expect(output.idleTimeoutMinutes == 60)
    }

    @Test("get on a missing config file falls back to defaults")
    func getScheduleMissingFile() throws {
        let url = tmpConfigURL()
        let output = try loadScheduleAvailability(configPath: url.path)
        #expect(output.enabled == false)
        #expect(output.windows == [])
    }

    // MARK: Write path

    @Test("set windows replaces the schedule and enables it")
    func setWindows() throws {
        let url = tmpConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeConfig(baseTOML, to: url)

        let plan = try ScheduleSetPlan.parse(["weekdays", "21:00-06:30", "sat,sun", "10:00-16:00"])
        let output = try applyScheduleAvailabilitySet(plan, configPath: url.path)
        #expect(output.enabled == true)
        #expect(output.windows.count == 2)
        #expect(output.windows[0].end == "06:30")
        #expect(output.idleTimeoutMinutes == 45)

        // Reloading from disk must see exactly what the CLI wrote.
        let reloaded = try ConfigManager.load(from: url)
        #expect(reloaded.schedule?.enabled == true)
        #expect(reloaded.schedule?.windows.count == 2)
        #expect(reloaded.schedule?.windows[0].days == ["mon", "tue", "wed", "thu", "fri"])
        // The written schedule must still serve under Schedule.from(config:):
        // a set that parses to nil would silently flip the provider to
        // "always available" — the grammar exists to prevent that.
        #expect(reloaded.schedule.flatMap { Schedule.from(config: $0) } != nil)
    }

    @Test("set always disables scheduling but keeps windows on disk")
    func setAlways() throws {
        let url = tmpConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeConfig(baseTOML, to: url)

        let output = try applyScheduleAvailabilitySet(.always, configPath: url.path)
        #expect(output.enabled == false)
        #expect(output.windows.count == 1, "windows stay so re-enabling restores them")

        let reloaded = try ConfigManager.load(from: url)
        #expect(reloaded.schedule?.enabled == false)
        #expect(reloaded.schedule?.windows.first?.start == "20:00")
    }

    @Test("set idle-timeout-minutes writes [backend] and leaves [schedule] alone")
    func setIdleTimeout() throws {
        let url = tmpConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeConfig(baseTOML, to: url)

        let output = try applyScheduleAvailabilitySet(.idleTimeoutMinutes(90), configPath: url.path)
        #expect(output.idleTimeoutMinutes == 90)
        #expect(output.enabled == true)

        let reloaded = try ConfigManager.load(from: url)
        #expect(reloaded.backend.idleTimeoutMins == 90)
        #expect(reloaded.schedule?.enabled == true)
        #expect(reloaded.schedule?.windows.count == 1)
    }

    @Test("set preserves every untouched section of the config")
    func setPreservesOtherSections() throws {
        let url = tmpConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeConfig(baseTOML, to: url)

        let plan = try ScheduleSetPlan.parse(["weekend", "10:00-16:00"])
        _ = try applyScheduleAvailabilitySet(plan, configPath: url.path)
        let reloaded = try ConfigManager.load(from: url)
        #expect(reloaded.provider.name == "testprovider")
        #expect(reloaded.provider.autoUpdate == false)
        #expect(reloaded.coordinator.url == "wss://example.test/ws/provider")
        #expect(reloaded.coordinator.heartbeatIntervalSecs == 7)
        #expect(reloaded.backend.model == "gemma-4-26b-qat-4bit")
        #expect(reloaded.backend.maxModelSlots == 2)
    }

    @Test("schedule payload encodes to parseable JSON with the contract keys")
    func payloadJSONShape() throws {
        let output = ScheduleAvailabilityOutput(
            enabled: true,
            windows: [ScheduleWindowOutput(days: ["sat", "sun"], start: "09:00", end: "18:00")],
            idleTimeoutMinutes: 60)
        let encoder = JSONEncoder()
        let data = try encoder.encode(output)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsed["enabled"] as? Bool == true)
        #expect(parsed["idle_timeout_minutes"] as? Int == 60)
        let windows = try #require(parsed["windows"] as? [[String: Any]])
        #expect(windows.first?["days"] as? [String] == ["sat", "sun"])
    }
}
