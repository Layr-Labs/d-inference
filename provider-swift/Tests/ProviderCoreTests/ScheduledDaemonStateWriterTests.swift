import Foundation
import Testing
@testable import ProviderCore

@Suite("Scheduled daemon-state authority")
struct ScheduledDaemonStateWriterTests {
    private func date(hour: Int, minute: Int = 0, second: Int = 0) throws -> Date {
        var components = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day],
            from: Date()
        )
        components.hour = hour
        components.minute = minute
        components.second = second
        return try #require(Calendar.current.date(from: components))
    }

    private func scheduleConfig() throws -> ScheduleConfig {
        let reference = try date(hour: 6)
        return ScheduleConfig(
            enabled: true,
            windows: [
                ScheduleWindow(
                    days: [dayAbbreviation(for: reference)],
                    start: "10:00",
                    end: "11:00"
                ),
            ]
        )
    }

    private func loopConfig(schedule: ScheduleConfig) -> ProviderLoopConfig {
        ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5",
                chipName: "Apple M4 Max",
                chipFamily: .m4,
                chipTier: .max,
                memoryGb: 128,
                memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40,
                memoryBandwidthGbs: 546
            ),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "scheduled-state-test"),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 5),
                schedule: schedule
            )
        )
    }

    private func temporaryStateURL() throws -> (directory: URL, state: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("daemon-state.json"))
    }

    @Test("initial off-window startup writes current process identity and stays watchdog-healthy")
    func initialOffWindowAndRefresh() async throws {
        let files = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let config = try scheduleConfig()
        let schedule = try #require(Schedule.from(config: config))
        let writer = ScheduledDaemonStateWriter(
            loopConfig: loopConfig(schedule: config),
            stateFileURL: files.state
        )
        let initialAt = try date(hour: 6)
        let activationAt = try date(hour: 10)

        await writer.persistInitialOffWindow(schedule: schedule, at: initialAt)
        var state = try #require(DaemonStateFile.read(from: files.state))

        #expect(state.pid == Int32(ProcessInfo.processInfo.processIdentifier))
        #expect(state.processIdentity == ProcessIdentity.current())
        #expect(state.schedule?.mode == "scheduled-off")
        #expect(state.schedule?.nextChangeAtEpoch
            == activationAt.timeIntervalSince1970)
        #expect(state.trust?.status == "offline")
        #expect(state.connectivity?.status == .disconnected)
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: initialAt.addingTimeInterval(90).timeIntervalSince1970
        ))
        #expect(!WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: initialAt.addingTimeInterval(90.001).timeIntervalSince1970
        ))

        // The runtime cadence refreshes well inside the stale boundary.
        #expect(ScheduledDaemonStateWriter.refreshIntervalSeconds < 90)
        #expect(ScheduledDaemonStateWriter.refreshDelay(
            untilNextActive: 4 * 60 * 60
        ) == ScheduledDaemonStateWriter.refreshIntervalSeconds)
        let lastRefresh = try date(hour: 9, minute: 59, second: 30)
        await writer.refresh(schedule: schedule, at: lastRefresh)
        state = try #require(DaemonStateFile.read(from: files.state))

        // The matching live process remains healthy through the activation
        // boundary; the serving loop takes state-file ownership from there.
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: activationAt.timeIntervalSince1970
        ))
        #expect(state.writtenAt == lastRefresh.timeIntervalSince1970)
        #expect(state.schedule?.mode == "scheduled-off")
    }

    @Test("active-window close hands real ProviderLoop state to the off-window writer")
    func activeToOffTransition() async throws {
        let files = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let config = try scheduleConfig()
        let parsed = try #require(Schedule.from(config: config))
        let providerConfig = loopConfig(schedule: config)
        let writer = ScheduledDaemonStateWriter(
            loopConfig: providerConfig,
            stateFileURL: files.state
        )
        let loop = try ProviderLoop(
            config: providerConfig,
            purgeLegacyFiles: false,
            attestationSigner: nil
        )
        await loop.setDaemonStateFileForTesting(files.state)
        let activeAt = try date(hour: 10, minute: 59, second: 30)
        let closedAt = try date(hour: 11)

        await loop.handleCoordinatorConnected(at: activeAt)
        await loop.handleTrustStatus(
            trustLevel: "hardware",
            status: "verified",
            reason: "MDM verification passed",
            at: activeAt
        )
        var state = try #require(DaemonStateFile.read(from: files.state))
        #expect(state.schedule?.mode == "scheduled-active")
        #expect(state.trust?.status == "verified")

        let transition = await loop.beginScheduledDowntime(at: closedAt)
        await writer.persistTransitionFromActive(
            transition,
            schedule: parsed,
            at: closedAt
        )
        state = try #require(DaemonStateFile.read(from: files.state))

        #expect(state.pid == Int32(ProcessInfo.processInfo.processIdentifier))
        #expect(state.processIdentity == ProcessIdentity.current())
        #expect(state.writtenAt == closedAt.timeIntervalSince1970)
        #expect(state.schedule?.mode == "scheduled-off")
        #expect((state.schedule?.nextChangeAtEpoch ?? 0) > closedAt.timeIntervalSince1970)
        #expect(state.trust?.status == "offline")
        #expect(state.connectivity?.status == .disconnected)
        #expect(state.currentModel == nil)
        #expect(state.warmModels.isEmpty)
        #expect(!state.inferenceActive)

        // Shutdown tasks from the retired loop may finish after the handoff.
        // Their periodic writes must not reclaim the file from the supervisor.
        let authoritativeOffState = state
        await loop.writeDaemonState()
        state = try #require(DaemonStateFile.read(from: files.state))
        #expect(state == authoritativeOffState)

        let refreshedAt = closedAt.addingTimeInterval(60)
        await writer.refresh(schedule: parsed, at: refreshedAt)
        state = try #require(DaemonStateFile.read(from: files.state))
        #expect(WatchdogProbe.providerActive(
            processRunning: true,
            daemonState: state,
            now: refreshedAt.addingTimeInterval(89).timeIntervalSince1970
        ))
    }
}

private func dayAbbreviation(for date: Date) -> String {
    switch Calendar.current.component(.weekday, from: date) {
    case 1: "sun"
    case 2: "mon"
    case 3: "tue"
    case 4: "wed"
    case 5: "thu"
    case 6: "fri"
    default: "sat"
    }
}
