import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-marker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Provider run marker and start reason")
struct ProviderRunMarkerTests {
    @Test func cleanRunningUncleanTransitions() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartedAt: 100) == .unknown)

        try marker.markRunning(processStartedAt: 100, version: "0.9.10", previousExit: .unknown)
        let mode = try FileManager.default.attributesOfItem(atPath: marker.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try marker.markClean(processStartedAt: 100, cause: .shutdown, now: Date(timeIntervalSince1970: 200))
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartedAt: 300) == .clean)

        // Next process starts, then dies without finishing its drain.
        try marker.markRunning(processStartedAt: 300, version: "0.9.10", previousExit: .clean)
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartedAt: 400) == .unclean)
    }

    @Test func staleProcessCannotMarkANewerRunClean() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        try marker.markRunning(processStartedAt: 500, version: "b", previousExit: .clean)
        try marker.markClean(processStartedAt: 100, cause: .shutdown)
        #expect(marker.read()?.state == .running)
    }

    @Test func inPlaceExecKeepsTheOriginalPreviousExit() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        try marker.markRunning(processStartedAt: 700, version: "0.9.9", previousExit: .unclean)
        // Same kernel process after a startup self-update exec.
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartedAt: 700) == .unclean)
    }

    @Test func corruptMarkerReadsAsUnknown() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        try Data("{not json".utf8).write(to: marker.url)
        #expect(marker.read() == nil)
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartedAt: 1) == .unknown)
    }

    @Test func beginClassifiesAndRecordsRunning() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProviderRunMarker(directory: dir).markRunning(processStartedAt: 1_000, version: "0.9.9", previousExit: .clean)
        let context = ProviderProcessRun.begin(directory: dir, version: "0.9.10", processStartedAt: 2_000.5,
                                               environment: ["XPC_SERVICE_NAME": LaunchAgent.label],
                                               now: Date(timeIntervalSince1970: 2_001))
        #expect(context.processStartedAt == 2_000)
        #expect(context.previousExit == .unclean)
        #expect(context.startReason == .update, "a different previous version wins over launchd")
        let written = ProviderRunMarker(directory: dir).read()
        #expect(written?.state == .running)
        #expect(written?.processStartedAt == 2_000)
        #expect(written?.previousExit == .unclean)
    }

    // MARK: - start_reason precedence

    private func evidence(previous: ProviderRunMarker.Record? = nil, stall: Double? = nil, watchdog: Double? = nil,
                          launchd: Bool = true) -> ProviderStartReason.Evidence {
        ProviderStartReason.Evidence(processStartedAt: 10_000, now: 10_030, previousRun: previous, currentVersion: "1",
                                     stallRestartAt: stall, watchdogRestartAt: watchdog, launchedByLaunchd: launchd)
    }

    @Test func startReasonPrecedenceAndRecency() {
        let recentExit = { (cause: ProviderRunMarker.ExitCause) in
            ProviderRunMarker.Record(state: .clean, processStartedAt: 1, version: "1", exitCause: cause, exitedAt: 9_990)
        }
        #expect(ProviderStartReason.classify(evidence(stall: 9_950, watchdog: 9_990)) == .stallRestart)
        #expect(ProviderStartReason.classify(evidence(previous: recentExit(.stallRestart))) == .stallRestart)
        #expect(ProviderStartReason.classify(evidence(watchdog: 9_990)) == .watchdog)
        #expect(ProviderStartReason.classify(evidence(previous: recentExit(.update))) == .update)
        #expect(ProviderStartReason.classify(evidence(previous: recentExit(.lifecycleCommand))) == .manual)
        #expect(ProviderStartReason.classify(evidence(launchd: false)) == .manual)
        #expect(ProviderStartReason.classify(evidence()) == .launchd)
        // Old evidence (a stall restart six hours ago, a watchdog restart from
        // yesterday, a clean stop long ago) does not explain this start.
        let oldExit = ProviderRunMarker.Record(state: .clean, processStartedAt: 1, version: "1",
                                               exitCause: .lifecycleCommand, exitedAt: 1_000)
        #expect(ProviderStartReason.classify(evidence(previous: oldExit, stall: 1_000, watchdog: 2_000)) == .launchd)
    }

    @Test func launchdDetectionNeedsTheProviderLabel() {
        #expect(ProviderStartReason.launchedByLaunchd(environment: ["XPC_SERVICE_NAME": LaunchAgent.label]))
        #expect(!ProviderStartReason.launchedByLaunchd(environment: ["XPC_SERVICE_NAME": "0"]))
        #expect(!ProviderStartReason.launchedByLaunchd(environment: [:]))
    }
}
