import Foundation
import Testing

@testable import ProviderCore

/// A fake launchd for one provider job. `bootout` returns at once but the job
/// stays listed for `listedAfterBootout` more `print` calls, the way launchd
/// keeps a job registered while its process is still exiting. `bootstrap`
/// fails with error 5 while the job is listed, which is what
/// `launchctl bootstrap` prints on macOS in that window.
private final class FakeLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var listed = true
    private var exitingPrints = 0
    private let listedAfterBootout: Int
    private let neverReleased: Bool
    private(set) var calls: [[String]] = []
    private(set) var bootstrapResults: [Int32] = []

    /// `neverReleased`: the job stays listed forever after bootout.
    init(listedAfterBootout: Int, neverReleased: Bool = false) {
        self.listedAfterBootout = listedAfterBootout
        self.neverReleased = neverReleased
    }

    var printCount: Int { lock.withLock { calls.filter { $0.first == "print" }.count } }
    var bootstrapCount: Int { lock.withLock { calls.filter { $0.first == "bootstrap" }.count } }

    func run(_ arguments: [String]) -> LaunchctlControl.Output {
        lock.withLock {
            calls.append(arguments)
            switch arguments.first {
            case "print":
                if neverReleased { return .init(status: 0, stdout: "", stderr: "") }
                if exitingPrints > 0 {
                    exitingPrints -= 1
                    if exitingPrints == 0 { listed = false }
                    return .init(status: 0, stdout: "", stderr: "")
                }
                return listed
                    ? .init(status: 0, stdout: "", stderr: "")
                    : .init(status: 113, stdout: "", stderr: "Could not find service")
            case "bootout":
                if neverReleased { return .init(status: 0, stdout: "", stderr: "") }
                exitingPrints = listedAfterBootout
                if listedAfterBootout == 0 { listed = false }
                return .init(status: 0, stdout: "", stderr: "")
            case "bootstrap":
                if listed {
                    bootstrapResults.append(5)
                    return .init(status: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error")
                }
                listed = true
                bootstrapResults.append(0)
                return .init(status: 0, stdout: "", stderr: "")
            default:
                return .init(status: 0, stdout: "", stderr: "")
            }
        }
    }
}

/// Runs `body` against `launchd` with a temporary home folder holding an
/// installed provider plist. No launchctl process is spawned.
private func withFakeLaunchd<T>(_ launchd: FakeLaunchd, _ body: () throws -> T) throws -> T {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchagent-relaunch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    return try LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
        let plist = LaunchAgent.plistPath()
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": LaunchAgent.label, "ProgramArguments": ["/usr/bin/true"]],
            format: .xml, options: 0)
        try data.write(to: plist)
        return try LaunchctlControl.$runnerForTesting.withValue({ launchd.run($0) }) {
            try body()
        }
    }
}

private final class SleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks = 0
    var count: Int { lock.withLock { ticks } }
    func tick() { lock.withLock { ticks += 1 } }
}

@Suite("LaunchAgent relaunch after drain")
struct LaunchAgentRelaunchTests {

    // #1306: `darkbloom update` and `darkbloom restart` boot the drained job
    // out and bootstrap it again. launchd keeps the job listed while the old
    // process exits, so an immediate bootstrap fails with error 5 and the
    // provider is left unloaded.
    @Test("relaunch waits for launchd to release the old job before bootstrapping")
    func waitsForOldJobBeforeBootstrap() throws {
        let launchd = FakeLaunchd(listedAfterBootout: 3)
        try withFakeLaunchd(launchd) {
            try LaunchAgent.restartAfterDrain(sleep: { _ in })
        }
        #expect(launchd.bootstrapResults == [0])
        #expect(launchd.calls.contains { $0.first == "kickstart" })
    }

    // A job that launchd never releases must end in a bounded wait and a
    // thrown error, not an endless poll. The wait must actually happen:
    // releaseTimeout / pollInterval sleeps, each preceded by a print.
    @Test("relaunch waits the full budget, then gives up with bootstrapFailed")
    func givesUpWhenJobNeverReleased() throws {
        let launchd = FakeLaunchd(listedAfterBootout: 0, neverReleased: true)
        let sleeps = SleepCounter()
        try withFakeLaunchd(launchd) {
            do {
                try LaunchAgent.restartAfterDrain(releaseTimeout: 1, pollInterval: 0.25, sleep: { _ in sleeps.tick() })
                Issue.record("expected bootstrapFailed")
            } catch LaunchAgentError.bootstrapFailed {
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
        #expect(sleeps.count == 4)
        #expect(launchd.printCount > 2)
        #expect(launchd.printCount <= 8)
        #expect(launchd.bootstrapCount == 1)
    }
}
