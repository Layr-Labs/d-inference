import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-marker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Provider run marker and start reason", .serialized)
struct ProviderRunMarkerTests {
    @Test func cleanRunningUncleanTransitions() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartMicros: 100_000_000) == .unknown)

        try marker.markRunning(processStartMicros: 100_000_000, version: "0.9.10", previousExit: .unknown)
        let mode = try FileManager.default.attributesOfItem(atPath: marker.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try marker.markClean(processStartMicros: 100_000_000, cause: .shutdown, now: Date(timeIntervalSince1970: 200))
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartMicros: 300_000_000) == .clean)

        // Next process starts, then dies without finishing its drain.
        try marker.markRunning(processStartMicros: 300_000_000, version: "0.9.10", previousExit: .clean)
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartMicros: 400_000_000) == .unclean)
    }

    @Test func staleProcessCannotMarkANewerRunClean() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        try marker.markRunning(processStartMicros: 500_000_000, version: "b", previousExit: .clean)
        try marker.markClean(processStartMicros: 100_000_000, cause: .shutdown)
        #expect(marker.read()?.state == .running)
    }

    @Test func inPlaceExecKeepsTheOriginalPreviousExit() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        try marker.markRunning(processStartMicros: 700_000_000, version: "0.9.9", previousExit: .unclean)
        // Same kernel process after a startup self-update exec.
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartMicros: 700_000_000) == .unclean)
    }

    @Test func launchesWithinTheSameSecondAreDifferentRuns() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        try marker.markRunning(processStartMicros: 5_000_000_100, version: "0.9.10", previousExit: .clean)
        // A replacement that starts in the same second after a crash is not an in-place exec.
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartMicros: 5_000_000_900) == .unclean)
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartMicros: 5_000_000_100) == .clean)
        try marker.markClean(processStartMicros: 5_000_000_900, cause: .shutdown)
        #expect(marker.read()?.state == .running, "a different process in the same second cannot mark it clean")
    }

    @Test func corruptMarkerReadsAsUnknown() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = ProviderRunMarker(directory: dir)
        try Data("{not json".utf8).write(to: marker.url)
        #expect(marker.read() == nil)
        #expect(ProviderRunMarker.previousExit(marker.read(), processStartMicros: 1_000_000) == .unknown)
    }

    @Test func beginClassifiesAndRecordsRunning() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProviderRunMarker(directory: dir).markRunning(processStartMicros: 1_000_000_000, version: "0.9.9", previousExit: .clean)
        let context = ProviderProcessRun.begin(directory: dir, version: "0.9.10", processStartMicros: 2_000_500_000,
                                               environment: ["XPC_SERVICE_NAME": LaunchAgent.label],
                                               now: Date(timeIntervalSince1970: 2_001))
        #expect(context.processStartedAt == 2_000)
        #expect(context.processStartMicros == 2_000_500_000)
        #expect(context.previousExit == .unclean)
        #expect(context.startReason == .launchd, "a version change without a recent update exit does not explain this start")
        let written = ProviderRunMarker(directory: dir).read()
        #expect(written?.state == .running)
        #expect(written?.processStartMicros == 2_000_500_000)
        #expect(written?.previousExit == .unclean)
    }

    @Test func explicitRelaunchCauseSurvivesGenericCleanupAndResetsOnResume() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for cause in [ProviderRunMarker.ExitCause.update, .stallRestart] {
            ProviderProcessRun.begin(directory: dir, version: "test", processStartMicros: 100_000_000)
            ProviderProcessRun.finish(cause: cause)
            ProviderProcessRun.noteLifecycleCommand()
            ProviderProcessRun.finish()
            ProviderProcessRun.finish(cause: .shutdown)
            #expect(ProviderRunMarker(directory: dir).read()?.exitCause == cause)
            ProviderProcessRun.resume()
            #expect(ProviderRunMarker(directory: dir).read()?.state == .running)
            ProviderProcessRun.finish()
            #expect(ProviderRunMarker(directory: dir).read()?.exitCause == .lifecycleCommand)
        }
        ProviderProcessRun.begin(directory: dir, version: "test", processStartMicros: 200_000_000)
        ProviderProcessRun.finish()
        #expect(ProviderRunMarker(directory: dir).read()?.exitCause == .shutdown, "new runs cannot inherit a relaunch cause")
    }

    @Test func concurrentCleanupCannotOverwriteAnUpdateCause() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        ProviderProcessRun.begin(directory: dir, version: "test", processStartMicros: 100_000_000)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { ProviderProcessRun.finish(cause: .update) }
            for _ in 0..<20 { group.addTask { ProviderProcessRun.finish() } }
        }
        #expect(ProviderRunMarker(directory: dir).read()?.exitCause == .update)
    }

    // MARK: - start_reason precedence

    private func evidence(previous: ProviderRunMarker.Record? = nil, stall: Double? = nil, watchdog: Double? = nil,
                          launchd: Bool = true) -> ProviderStartReason.Evidence {
        ProviderStartReason.Evidence(processStartedAt: 10_000, now: 10_030, previousRun: previous, currentVersion: "1",
                                     stallRestartAt: stall, watchdogRestartAt: watchdog, launchedByLaunchd: launchd)
    }

    @Test func startReasonPrecedenceAndRecency() {
        let recentExit = { (cause: ProviderRunMarker.ExitCause) in
            ProviderRunMarker.Record(state: .clean, processStartMicros: 1_000_000, version: "1", exitCause: cause, exitedAt: 9_990)
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
        let oldExit = ProviderRunMarker.Record(state: .clean, processStartMicros: 1_000_000, version: "1",
                                               exitCause: .lifecycleCommand, exitedAt: 1_000)
        #expect(ProviderStartReason.classify(evidence(previous: oldExit, stall: 1_000, watchdog: 2_000)) == .launchd)
    }

    @Test func updateRequiresRecentExitOrExactExecIdentity() {
        let old = ProviderRunMarker.Record(state: .clean, processStartMicros: 1_000_000, version: "0",
                                           exitCause: .update, exitedAt: 1_000)
        #expect(ProviderStartReason.classify(evidence(previous: old)) == .launchd)
        #expect(ProviderStartReason.classify(evidence(previous: old, launchd: false)) == .manual)
        let recent = ProviderRunMarker.Record(state: .clean, processStartMicros: 1_000_000, version: "0",
                                              exitCause: .update, exitedAt: 9_990)
        #expect(ProviderStartReason.classify(evidence(previous: recent)) == .update)
        var current = evidence(previous: .init(state: .running, processStartMicros: 10_000_000_100, version: "0"))
        #expect(ProviderStartReason.classify(current) == .launchd, "unknown identity cannot prove exec")
        current.processStartMicros = 10_000_000_100
        #expect(ProviderStartReason.classify(current) == .update)
        current.processStartMicros = 10_000_000_900
        #expect(ProviderStartReason.classify(current) == .launchd, "same second is not the same kernel process")
    }

    @Test func launchdDetectionNeedsTheProviderLabel() {
        #expect(ProviderStartReason.launchedByLaunchd(environment: ["XPC_SERVICE_NAME": LaunchAgent.label]))
        #expect(!ProviderStartReason.launchedByLaunchd(environment: ["XPC_SERVICE_NAME": "0"]))
        #expect(!ProviderStartReason.launchedByLaunchd(environment: [:]))
    }
}
