import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Schedule CLI regression tests")
struct ScheduleCommandTests {
    private let weekdays = ["mon", "tue", "wed", "thu", "fri"]
    private let daily = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    private func settings(enabled: Bool? = nil, preload: Bool = true) -> ScheduleSettings {
        var config = ProviderConfig(provider: ProviderSettings(name: "schedule-test"))
        config.backend.startupPreload = preload
        if let enabled {
            config.schedule = ScheduleConfig(enabled: enabled, windows: [
                ScheduleWindow(days: ["mon", "fri"], start: "21:30", end: "07:15")
            ])
        }
        return ScheduleSettings(config: config)
    }

    private func answer(
        _ lines: [String?], current: ScheduleSettings? = nil, starting: Bool = false
    ) -> (draft: ScheduleSettings?, output: String, consumed: Int) {
        var consumed = 0
        var output = ""
        let wizard = ScheduleWizard(readInput: {
            guard consumed < lines.count else {
                Issue.record("Wizard requested unexpected input after script exhaustion")
                return nil
            }
            defer { consumed += 1 }
            return lines[consumed]
        }, emit: { output += $0 })
        let draft = wizard.run(current: current ?? settings(), idleMinutes: 45,
            preloadModels: ["selected-a", "selected-b"], starting: starting)
        return (draft, output, consumed)
    }

    private func tempConfig(_ content: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("custom-provider.toml")
        try content.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    private var fixture: String {
        """
        # Preserve these bytes when the editor makes no changes.
        [provider]
        name = "schedule-fixture"
        memory_reserve_gb = 7
        auto_update = false
        auto_restart = false
        update_jitter_seconds = 19

        [backend]
        port = 8123
        model = "selected-a"
        model_cache_directory = "./fixture-cache"
        enabled_models = ["selected-a", "selected-b"]
        preload_models = ["selected-b", "not-selected"]
        startup_preload = true
        idle_timeout_mins = 45
        max_model_slots = 2
        engine_v2_max_concurrent = 3

        [coordinator]
        url = "wss://schedule-fixture.invalid/ws/provider"
        heartbeat_interval_secs = 17
        private_only = true

        [schedule]
        enabled = true
        [[schedule.windows]]
        days = ["mon", "fri"]
        start = "21:30"
        end = "07:15"

        [gemma_optimizations]
        prefill_layer18 = false
        weighted_r1 = false
        """
    }

    @Test("day lists, full names, aliases and inclusive ranges normalize in week order")
    func parseDays() {
        let cases: [(String, [String])] = [
            ("SUN, Monday,wed,mon", ["mon", "wed", "sun"]),
            ("Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday", daily),
            (" weekdays ", weekdays), ("WEEKENDS", ["sat", "sun"]),
            ("daily", daily), ("all", daily), ("everyday", daily),
            ("mon-fri", weekdays), (" Friday - Monday ", ["mon", "fri", "sat", "sun"]),
            ("sun-tue", ["mon", "tue", "sun"]), ("sun-mon", ["mon", "sun"]),
            ("wed-wed", ["wed"]), ("tue-mon", daily),
            ("mon-wed,wed-fri,sunday", weekdays + ["sun"])
        ]
        for (input, expected) in cases {
            #expect(ScheduleWizard.parseDays(input) == expected, "Input: \(input)")
        }
    }

    @Test("invalid days and malformed lists/ranges are rejected, not partly accepted")
    func invalidDays() {
        for input in ["", " ", "funday", "mon,funday", "mon,", ",mon", "mon,,tue",
            "mon-", "-fri", "mon-tue-wed", "weekdays,sun", "weekends-mon", "mon tue"] {
            #expect(ScheduleWizard.parseDays(input) == nil, "Input: \(input)")
        }
    }

    @Test("times use ASCII 24-hour HH:MM and reject malformed/out-of-range input")
    func parseTime() {
        for input in ["00:00", "00:01", "09:05", "12:00", "23:59"] {
            #expect(ScheduleWizard.parseTime(input) == input)
        }
        for input in ["", "9:05", "09:5", "24:00", "23:60", "-1:00", "+1:00",
            "009:05", "09:005", "09::05", "09:05:00", "09:05am", " 09:05 ",
            "09:", ":05", "ab:cd", "０９:０５"] {
            #expect(ScheduleWizard.parseTime(input) == nil, "Input: \(input)")
        }
    }

    @Test("overnight and full-day presets support preload and on-demand loading")
    func presets() throws {
        for preload in [true, false] {
            let loading = preload ? "1" : "2"
            let overnight = answer(["3", "d", loading, "y"])
            let night = try #require(overnight.draft)
            #expect(night.schedule == ScheduleConfig(enabled: true, windows: [
                ScheduleWindow(days: weekdays, start: "22:00", end: "08:00")
            ]))
            #expect(night.preload == preload)
            #expect(overnight.output.contains("ends the following day"))

            let weekend = answer(["4", "d", loading, "yes"])
            let fullDay = try #require(weekend.draft)
            #expect(fullDay.schedule == ScheduleConfig(enabled: true, windows: [
                ScheduleWindow(days: ["sat", "sun"], start: "00:00", end: "00:00")
            ]))
            #expect(fullDay.preload == preload)
            #expect(weekend.output.contains("24 hours, ending the following day"))
            #expect(weekend.output.contains(preload ? "Existing preload list:" : "Loading: on demand"))
        }
    }

    @Test("Enter keeps saved windows, enabled state and loading; saved windows can be explicitly re-enabled")
    func savedDefaults() throws {
        for enabled in [true, false] {
            for preload in [true, false] {
                let current = settings(enabled: enabled, preload: preload)
                let result = answer(enabled ? ["", "", "", "y"] : ["", "", "y"], current: current)
                #expect(try #require(result.draft) == current)
                #expect(result.consumed == (enabled ? 4 : 3))
                if !enabled {
                    var expected = current
                    expected.schedule?.enabled = true
                    #expect(try #require(answer(["1", "", "", "y"], current: current).draft) == expected)
                }
            }
        }
        let always = settings(preload: false)
        #expect(try #require(answer(["", "", "y"], current: always).draft) == always)
    }

    @Test("always-available choice disables saved windows without deleting them")
    func disablePreservesSavedWindows() throws {
        let current = settings(enabled: true, preload: false)
        let result = try #require(answer(["2", "", "y"], current: current).draft)
        #expect(result == AvailabilitySchedule.disabled(current))
        #expect(result.schedule?.windows == current.schedule?.windows)
        #expect(result.preload == false)
        #expect(AvailabilitySchedule.disabled(settings()).schedule == nil)
    }

    @Test("custom editor adds multiple windows, edits and removes the selected window")
    func customMultipleWindows() throws {
        let result = answer([
            "5", "fri-mon", "22:00", "08:00",
            "a", "weekends", "00:00", "00:00",
            "e", "1", "Tuesday", "19:30", "23:45",
            "a", "wed", "10:00", "11:00", "r", "3", "d", "2", "y"
        ])
        let draft = try #require(result.draft)
        #expect(draft.schedule == ScheduleConfig(enabled: true, windows: [
            ScheduleWindow(days: ["tue"], start: "19:30", end: "23:45"),
            ScheduleWindow(days: ["sat", "sun"], start: "00:00", end: "00:00")
        ]))
        #expect(draft.preload == false)
        #expect(result.consumed == 22)
    }

    @Test("editing an existing window with Enter preserves all its fields")
    func editKeepsDefaults() throws {
        let current = settings(enabled: true)
        let result = answer(["5", "e", "", "", "", "", "d", "", "y"], current: current)
        #expect(try #require(result.draft) == current)
    }

    @Test("every invalid prompt answer is re-asked without accepting a partial window")
    func invalidAnswersReprompt() throws {
        let result = answer([
            "0", "1", "5", "bogus", "mon,", "weekdays",
            "24:00", "22:00", "23:60", "08:00",
            "x", "e", "0", "2", "1", "", "", "",
            "d", "3", "2", "maybe", "yes"
        ])
        let draft = try #require(result.draft)
        #expect(draft.schedule?.windows == [ScheduleWindow(days: weekdays, start: "22:00", end: "08:00")])
        #expect(draft.preload == false)
        for problem in ["Choose 1-5", "Enter valid days", "Use a time", "Choose a, e, r or d",
            "Choose an existing window number", "Choose 1 or 2", "Enter y or n"] {
            #expect(result.output.contains(problem))
        }
        #expect(result.consumed == 23)
    }

    @Test("removing the last window cannot finish until a valid replacement is added")
    func removingAllRequiresReplacement() throws {
        let result = answer(["1", "r", "1", "d", "e", "r", "a", "sun", "12:00", "12:00", "d", "1", "y"],
            current: settings(enabled: true))
        #expect(try #require(result.draft).schedule?.windows == [
            ScheduleWindow(days: ["sun"], start: "12:00", end: "12:00")
        ])
        #expect(result.output.contains("at least one availability window"))
        #expect(result.output.contains("No windows to edit or remove"))
    }

    @Test("q, cancel and EOF cancel at every prompt without touching config bytes")
    func cancellationAtEveryPrompt() throws {
        let path = try tempConfig(fixture)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let before = try Data(contentsOf: path)
        let current = ScheduleSettings(config: try ConfigManager.load(from: path))
        // Every prefix ends immediately before a real prompt, covering both
        // add/edit fields, remove selection, loading and final confirmation.
        let scripts: [([String], ScheduleSettings)] = [
            (["2", "1", "y"], current),
            (["3", "d", "1", "y"], current),
            (["4", "d", "2", "y"], current),
            (["5", "sun", "22:00", "08:00", "a", "sat", "12:00", "12:00",
                "e", "2", "fri", "21:00", "07:00", "r", "1", "d", "2", "y"], settings()),
            (["1", "e", "1", "", "", "", "d", "1", "y"], current)
        ]
        for (script, initial) in scripts {
            for index in script.indices {
                for cancellation: String? in ["q", " Q ", "cancel", nil] {
                    var lines = script.prefix(index).map { Optional($0) }
                    lines.append(cancellation)
                    let result = answer(lines, current: initial)
                    if let draft = result.draft {
                        Issue.record("Cancellation unexpectedly returned a draft at prompt \(index)")
                        try draft.save(configPath: path.path, expected: current)
                    }
                    #expect(result.draft == nil)
                    #expect(result.consumed == index + 1)
                    #expect(try Data(contentsOf: path) == before)
                }
            }
        }
    }

    @Test("no or Enter at final confirmation cancels both editor and start wizard")
    func finalNoDoesNotSave() throws {
        let path = try tempConfig(fixture)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let before = try Data(contentsOf: path)
        let current = ScheduleSettings(config: try ConfigManager.load(from: path))
        for starting in [true, false] {
            for no in ["n", "no", ""] {
                let result = answer(["3", "d", "2", no], current: current, starting: starting)
                #expect(result.draft == nil)
                #expect(result.output.contains(starting
                    ? "Save these settings and continue starting?" : "Save these settings?"))
                #expect(try Data(contentsOf: path) == before)
            }
        }
    }

    @Test("save updates only schedule/startup_preload at the custom config path")
    func savePreservesUnrelatedSettings() throws {
        let path = try tempConfig(fixture)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let original = try ConfigManager.load(from: path)
        let expected = ScheduleSettings(config: original)
        let draft = try #require(answer(["4", "d", "2", "y"], current: expected).draft)
        #expect(try draft.save(configPath: path.path, expected: expected))
        let saved = try ConfigManager.load(from: path)
        var desired = original
        draft.apply(to: &desired)
        #expect(saved == desired)
        #expect(saved.backend.enabledModels == ["selected-a", "selected-b"])
        #expect(saved.backend.preloadModels == ["selected-b", "not-selected"])
        #expect(saved.backend.idleTimeoutMins == 45)
        #expect(saved.coordinator == original.coordinator)
        #expect(saved.provider == original.provider)
        #expect(saved.gemmaOptimizations == original.gemmaOptimizations)
        #expect(saved.backend.startupPreload == false)
        #expect(saved.schedule == draft.schedule)
    }

    @Test("saving unchanged settings is a byte-exact no-op, including comments")
    func noOpPreservesExactBytes() throws {
        let path = try tempConfig(fixture)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let before = try Data(contentsOf: path)
        let current = ScheduleSettings(config: try ConfigManager.load(from: path))
        let draft = try #require(answer(["", "", "", "y"], current: current).draft)
        #expect(try draft.save(configPath: path.path, expected: current) == false)
        #expect(try Data(contentsOf: path) == before)
    }

    @Test("confirmed preload selection persists when previously loading on demand")
    func enablePreloadPersists() throws {
        let path = try tempConfig(fixture.replacingOccurrences(of: "startup_preload = true", with: "startup_preload = false"))
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let original = try ConfigManager.load(from: path)
        let current = ScheduleSettings(config: original)
        let draft = try #require(answer(["", "d", "1", "y"], current: current).draft)
        #expect(try draft.save(configPath: path.path, expected: current))
        var expected = original
        expected.backend.startupPreload = true
        #expect(try ConfigManager.load(from: path) == expected)
    }

    @Test("show is read-only and disable preserves windows and unrelated settings")
    func showAndDisableCommandPersistence() async throws {
        let path = try tempConfig(fixture)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let before = try Data(contentsOf: path)
        var original = try ConfigManager.load(from: path)
        var show = try AvailabilitySchedule.parse(["--show", "--config", path.path])
        try await show.run()
        #expect(try Data(contentsOf: path) == before)
        var disable = try AvailabilitySchedule.parse(["--disable", "--config", path.path])
        try await disable.run()
        original.schedule?.enabled = false
        #expect(try ConfigManager.load(from: path) == original)
        let disabledBytes = try Data(contentsOf: path)
        try await disable.run()
        #expect(try Data(contentsOf: path) == disabledBytes)
    }

    @Test("stale availability or preload settings reject save without overwriting bytes")
    func concurrentSettingsGuard() throws {
        for changeSchedule in [true, false] {
            let path = try tempConfig(fixture)
            defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
            var concurrent = try ConfigManager.load(from: path)
            let original = ScheduleSettings(config: concurrent)
            let draft = try #require(answer(["4", "d", "2", "y"], current: original).draft)
            if changeSchedule {
                concurrent.schedule?.windows[0].start = "20:00"
            } else {
                concurrent.backend.startupPreload = false
            }
            try ConfigManager.save(concurrent, to: path)
            let before = try Data(contentsOf: path)
            #expect(throws: ValidationError.self) {
                try draft.save(configPath: path.path, expected: original)
            }
            #expect(try Data(contentsOf: path) == before)
            // The guard also runs for an otherwise unchanged draft.
            #expect(throws: ValidationError.self) {
                try original.save(configPath: path.path, expected: original)
            }
            #expect(try Data(contentsOf: path) == before)
        }
    }

    @Test("unrelated concurrent settings survive a schedule save")
    func concurrentUnrelatedSettingsPreserved() throws {
        let path = try tempConfig(fixture)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var concurrent = try ConfigManager.load(from: path)
        let original = ScheduleSettings(config: concurrent)
        let draft = try #require(answer(["4", "d", "2", "y"], current: original).draft)
        concurrent.backend.enabledModels = ["new-selection"]
        concurrent.backend.preloadModels = ["new-preload"]
        concurrent.backend.idleTimeoutMins = 90
        concurrent.provider.name = "concurrent-name"
        concurrent.coordinator.privateOnly = false
        try ConfigManager.save(concurrent, to: path)
        #expect(try draft.save(configPath: path.path, expected: original))
        draft.apply(to: &concurrent)
        #expect(try ConfigManager.load(from: path) == concurrent)
    }

    @Test("invalid enabled schedules are rejected before writing; disabling remains safe")
    func invalidSaveDoesNotWrite() throws {
        let path = try tempConfig(fixture)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let current = ScheduleSettings(config: try ConfigManager.load(from: path))
        let before = try Data(contentsOf: path)
        var invalid = current
        invalid.schedule = ScheduleConfig(enabled: true)
        #expect(throws: (any Error).self) {
            try invalid.save(configPath: path.path, expected: current)
        }
        #expect(try Data(contentsOf: path) == before)
        invalid.schedule?.windows = [ScheduleWindow(days: ["bogus"], start: "24:00", end: "08:00")]
        #expect(throws: (any Error).self) {
            try invalid.save(configPath: path.path, expected: current)
        }
        #expect(try Data(contentsOf: path) == before)
        let disabled = AvailabilitySchedule.disabled(invalid)
        #expect(try disabled.save(configPath: path.path, expected: current))
        #expect(try ConfigManager.load(from: path).schedule == disabled.schedule)
    }

    @Test("root recognizes schedule and its mutually exclusive show/disable flags")
    func commandParsing() throws {
        for arguments in [[], ["--show"], ["--disable"]] {
            let command = try #require(try Darkbloom.parseAsRoot(
                ["schedule", "--config", "/fixture/custom-provider.toml"] + arguments) as? AvailabilitySchedule)
            #expect(command.configOptions.config == "/fixture/custom-provider.toml")
            #expect(command.show == arguments.contains("--show"))
            #expect(command.disable == arguments.contains("--disable"))
        }
        #expect(throws: (any Error).self) {
            _ = try Darkbloom.parseAsRoot(["schedule", "--show", "--disable"])
        }
        let start = try #require(try Darkbloom.parseAsRoot([
            "start", "--schedule", "--local-endpoint", "--config", "/fixture/custom-provider.toml"
        ]) as? Start)
        #expect(start.schedule)
        #expect(start.localEndpoint)
        #expect(start.configOptions.config == "/fixture/custom-provider.toml")
        #expect(try Start.parse([]).schedule == false)
    }

    @Test("non-interactive wizard rejects before loading config or starting a provider")
    func terminalGuard() {
        #expect(throws: ValidationError.self) {
            try AvailabilitySchedule.requireInteractiveTerminal(interactive: false)
        }
        #expect(throws: Never.self) {
            try AvailabilitySchedule.requireInteractiveTerminal(interactive: true)
        }
    }
}
