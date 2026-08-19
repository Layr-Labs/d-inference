import Foundation
import Testing
@testable import DarkbloomApp
import ProviderCoreFoundation

// Live AvailabilityStore: reads the persisted schedule through the CLI
// adapter, posture through the daemon state file, persists through the CLI,
// and reports requires-restart instead of pretending a restart happened.
@Suite("AvailabilityStore live mode")
struct AvailabilityLiveTests {

    actor StubCLI: AvailabilityCLIRunning {
        private(set) var appliedArguments: [[String]] = []
        nonisolated(unsafe) var schedule: AvailabilityCLISchedule?
        nonisolated(unsafe) var error: (any Error)?

        func fetchSchedule() async throws -> AvailabilityCLISchedule {
            if let error { throw error }
            guard let schedule else {
                throw AvailabilityCLIError.invalidOutput("stub has no schedule")
            }
            return schedule
        }

        func apply(arguments: [String]) async throws {
            if let error { throw error }
            appliedArguments.append(arguments)
        }
    }

    private func stateFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dstate-avail-\(UUID().uuidString).json")
    }

    private func writeState(scheduleMode: String, summary: String, nextChange: Double?) -> URL {
        let url = stateFileURL()
        var state = DaemonState(
            pid: 4321, version: "0.9.0",
            writtenAt: Date().timeIntervalSince1970,
            startedAt: Date().timeIntervalSince1970 - 3600)
        state.schedule = DaemonState.SchedulePosture(
            mode: scheduleMode, summary: summary, nextChangeAtEpoch: nextChange)
        DaemonStateFile.write(state, to: url)
        return url
    }

    // MARK: Read path

    @Test("loads the persisted schedule and the daemon posture")
    @MainActor
    func loadsScheduleAndPosture() async throws {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(
            enabled: true,
            windows: [AvailabilityCLISchedule.Window(days: ["mon", "tue", "wed", "thu", "fri"], start: "20:00", end: "07:00")],
            idleTimeoutMinutes: 45)
        let stateURL = writeState(scheduleMode: "scheduled-active", summary: "Mon-Fri 20:00-07:00", nextChange: Date().timeIntervalSince1970 + 3_600)
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let store = AvailabilityStore(cli: cli, stateFileURL: stateURL)
        #expect(store.isLive)
        #expect(store.loadState == .loading)

        await store.refresh()

        guard case .ready = store.loadState else {
            Issue.record("expected ready, got \(store.loadState)")
            return
        }
        #expect(store.savedPolicy?.mode == .scheduled)
        #expect(store.savedPolicy?.windows.count == 1)
        #expect(store.savedPolicy?.windows.first?.start.minutesSinceMidnight == 20 * 60)
        #expect(store.savedPolicy?.windows.first?.end.minutesSinceMidnight == 7 * 60)
        #expect(store.savedPolicy?.idleUnloadMinutes == 45)
        #expect(store.draft == store.savedPolicy)
        #expect(store.runtime?.state == .available)
        #expect(store.runtime?.nextObservedTransitionAt != nil)
    }

    @Test("daemon-reporting scheduled-off maps onto the runtime observation")
    @MainActor
    func scheduledOffRuntime() async {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(enabled: true, windows: [
            AvailabilityCLISchedule.Window(days: ["mon"], start: "09:00", end: "10:00"),
        ], idleTimeoutMinutes: 60)
        let boundary = Date().timeIntervalSince1970 + 7_200
        let stateURL = writeState(scheduleMode: "scheduled-off", summary: "Mon 09:00-10:00", nextChange: boundary)
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let store = AvailabilityStore(cli: cli, stateFileURL: stateURL)
        await store.refresh()

        #expect(store.runtime?.state == .scheduledOff)
        #expect(store.runtime?.nextObservedTransitionAt == Date(timeIntervalSince1970: boundary))
    }

    @Test("missing/!enabled schedule resolves to whenever-running (not malformed)")
    @MainActor
    func disabledScheduleResolvesAlways() async {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(enabled: false, windows: [], idleTimeoutMinutes: 0)
        let stateURL = stateFileURL() // no state file at all
        let store = AvailabilityStore(cli: cli, stateFileURL: stateURL)
        await store.refresh()

        #expect(store.savedPolicy?.mode == .wheneverRunning)
        #expect(store.savedPolicy?.idleUnloadingIsDisabled == true)
        #expect(store.runtime == nil)
    }

    @Test("a malformed saved schedule stays a distinct malformed state")
    @MainActor
    func malformedSchedule() async {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(enabled: true, windows: [
            AvailabilityCLISchedule.Window(days: ["mon"], start: "25:99", end: "07:00"),
        ], idleTimeoutMinutes: 60)
        let stateURL = stateFileURL()
        let store = AvailabilityStore(cli: cli, stateFileURL: stateURL)
        await store.refresh()

        guard case .malformed(_, let issues) = store.loadState else {
            Issue.record("expected malformed, got \(store.loadState)")
            return
        }
        #expect(!issues.isEmpty)
        #expect(store.savedPolicy == nil)
        #expect(store.draft == nil)
    }

    @Test("CLI absence falls back to the always-available default with a stale banner")
    @MainActor
    func cliFailureFallbackAlwaysAvailable() async {
        let cli = StubCLI()
        cli.error = AvailabilityCLIError.cliNotFound
        let stateURL = stateFileURL()
        let store = AvailabilityStore(cli: cli, stateFileURL: stateURL)
        await store.refresh()

        #expect(store.savedPolicy?.mode == .wheneverRunning)
        guard case .stale(_, let message) = store.loadState else {
            Issue.record("expected stale fallback, got \(store.loadState)")
            return
        }
        #expect(message.contains("CLI is not installed") || message.contains("could not read"))
        #expect(message.contains("always-available default"))
    }

    @Test("CLI failure WITH a live scheduled daemon cannot edit blind: distinct malformed state")
    @MainActor
    func cliFailureUnderLiveScheduleIsMalformed() async {
        let cli = StubCLI()
        cli.error = AvailabilityCLIError.cliNotFound
        let stateURL = writeState(scheduleMode: "scheduled-active", summary: "Mon 09:00-10:00", nextChange: Date().timeIntervalSince1970 + 600)
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let store = AvailabilityStore(cli: cli, stateFileURL: stateURL)
        await store.refresh()

        guard case .malformed(let message, _) = store.loadState else {
            Issue.record("expected malformed, got \(store.loadState)")
            return
        }
        #expect(message.contains("schedule is active"))
        #expect(store.savedPolicy == nil)
    }

    // MARK: Write path

    @Test("saving a whenever-running draft sends `config set schedule always` and requires restart")
    @MainActor
    func saveAlways() async throws {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(enabled: true, windows: [
            AvailabilityCLISchedule.Window(days: ["mon"], start: "09:00", end: "10:00"),
        ], idleTimeoutMinutes: 60)
        let store = AvailabilityStore(cli: cli, stateFileURL: stateFileURL())
        await store.refresh()
        let original = try #require(store.savedPolicy)

        store.setMode(.wheneverRunning)
        #expect(store.hasUnsavedChanges)
        let saveDate = Date(timeIntervalSince1970: 1_800_000_000)
        await store.saveAndRestartPreview(at: saveDate)

        #expect(store.saveState == .savedRequiresRestart(at: saveDate))
        #expect(store.requiresRestart)
        #expect(await cli.appliedArguments == [["config", "set", "schedule", "always"]])
        #expect(store.savedPolicy?.mode == .wheneverRunning)
        #expect(store.savedPolicy != original)

        store.dismissSaveResult()
        #expect(!store.requiresRestart)
    }

    @Test("saving a scheduled draft sends day/time pairs in CLI grammar")
    @MainActor
    func saveScheduled() async throws {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(enabled: false, windows: [], idleTimeoutMinutes: 60)
        let store = AvailabilityStore(cli: cli, stateFileURL: stateFileURL())
        await store.refresh()

        store.setMode(.scheduled)
        store.addWindow(AvailabilityWindow(
            id: "night",
            days: [.friday, .saturday],
            start: try #require(AvailabilityTimeOfDay(hour: 22, minute: 30)),
            end: try #require(AvailabilityTimeOfDay(hour: 6, minute: 0))))

        await store.saveAndRestartPreview()

        #expect(await cli.appliedArguments == [[
            "config", "set", "schedule", "fri,sat", "22:30-06:00",
        ]])
        #expect(store.requiresRestart)

        // Editing the draft again AFTER a save clears the banner.
        store.setIdleUnloadMinutes(60)
        #expect(!store.requiresRestart)
    }

    @Test("an idle-only edit persists only the idle knob")
    @MainActor
    func saveIdleOnly() async {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(enabled: false, windows: [], idleTimeoutMinutes: 60)
        let store = AvailabilityStore(cli: cli, stateFileURL: stateFileURL())
        await store.refresh()

        store.setIdleUnloadMinutes(120)
        await store.saveAndRestartPreview()

        #expect(await cli.appliedArguments == [[
            "config", "set", "schedule", "idle-timeout-minutes", "120",
        ]])
        #expect(store.saveState.isSaving == false)
        #expect(store.requiresRestart)
    }

    @Test("a failed live save retains both the draft and the persisted policy")
    @MainActor
    func saveFailureRetains() async throws {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(enabled: false, windows: [], idleTimeoutMinutes: 60)
        let store = AvailabilityStore(cli: cli, stateFileURL: stateFileURL())
        await store.refresh()
        let original = try #require(store.savedPolicy)

        cli.error = AvailabilityCLIError.exited(1, message: "unknown config key")
        store.setMode(.scheduled)
        store.addWindow(AvailabilityWindow(
            id: "w",
            days: [.monday],
            start: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0)),
            end: try #require(AvailabilityTimeOfDay(hour: 10, minute: 0))))
        let edit = store.draft

        await store.saveAndRestartPreview()

        guard case .failed(let message) = store.saveState else {
            Issue.record("expected failed, got \(store.saveState)")
            return
        }
        #expect(message.contains("unknown config key"))
        #expect(message.contains("changes are still here"))
        #expect(store.savedPolicy == original)
        #expect(store.draft == edit)
        #expect(store.hasUnsavedChanges)
        #expect(!store.requiresRestart)
    }

    @Test("invalid drafts never reach the CLI")
    @MainActor
    func invalidDraftRejected() async throws {
        let cli = StubCLI()
        cli.schedule = AvailabilityCLISchedule(enabled: false, windows: [], idleTimeoutMinutes: 60)
        let store = AvailabilityStore(cli: cli, stateFileURL: stateFileURL())
        await store.refresh()

        store.setMode(.scheduled)
        store.addWindow(AvailabilityWindow(
            id: "equal",
            days: [.friday],
            start: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0)),
            end: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0))))

        await store.saveAndRestartPreview()

        guard case .validationFailed = store.saveState else {
            Issue.record("expected validationFailed, got \(store.saveState)")
            return
        }
        #expect(await cli.appliedArguments.isEmpty)
    }
}

// MARK: - Adapter parsing + argument building

@Suite("AvailabilityCLI payload parsing + arguments")
struct AvailabilityCLIParsingTests {
    @Test("decodes the CLI's get-schedule JSON, tolerating a missing idle key")
    func decode() throws {
        let withIdle = """
        {"enabled": true, "windows": [{"days": ["mon", "wed"], "start": "20:00", "end": "07:00"}], "idle_timeout_minutes": 90}
        """
        let decoded = try JSONDecoder().decode(AvailabilityCLISchedule.self, from: Data(withIdle.utf8))
        #expect(decoded.enabled)
        #expect(decoded.windows.count == 1)
        #expect(decoded.idleTimeoutMinutes == 90)

        let legacy = """
        {"enabled": false, "windows": []}
        """
        let legacyDecoded = try JSONDecoder().decode(AvailabilityCLISchedule.self, from: Data(legacy.utf8))
        #expect(legacyDecoded.idleTimeoutMinutes == nil, "older CLIs predate the idle key; decode tolerates")
    }

    @Test("policy -> CLI arguments cover both modes and the idle knob")
    func argumentsForPolicy() throws {
        var scheduled = AvailabilityPolicy(mode: .scheduled)
        scheduled.windows = [
            AvailabilityWindow(
                id: "w",
                days: [.sunday, .monday],
                start: try #require(AvailabilityTimeOfDay(hour: 9, minute: 30)),
                end: try #require(AvailabilityTimeOfDay(hour: 17, minute: 45))),
        ]
        #expect(AvailabilityScheduleCLIArguments.scheduleArguments(for: scheduled) == [
            "config", "set", "schedule", "mon,sun", "09:30-17:45",
        ])
        #expect(AvailabilityScheduleCLIArguments.idleUnloadArguments(for: scheduled) == [
            "config", "set", "schedule", "idle-timeout-minutes", "60",
        ])

        let always = AvailabilityPolicy(mode: .wheneverRunning)
        #expect(AvailabilityScheduleCLIArguments.scheduleArguments(for: always) == [
            "config", "set", "schedule", "always",
        ])
    }

    @Test("window days emit in canonical week order, not set order")
    func daysSorted() throws {
        var policy = AvailabilityPolicy(mode: .scheduled)
        policy.windows = [
            AvailabilityWindow(
                id: "w",
                days: [.saturday, .tuesday, .friday],
                start: try #require(AvailabilityTimeOfDay(hour: 20, minute: 0)),
                end: try #require(AvailabilityTimeOfDay(hour: 7, minute: 0))),
        ]
        #expect(AvailabilityScheduleCLIArguments.scheduleArguments(for: policy) == [
            "config", "set", "schedule", "tue,fri,sat", "20:00-07:00",
        ])
    }
}
