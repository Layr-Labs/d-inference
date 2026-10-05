import Foundation
import Testing
@testable import ProviderCore

// The scoped command/home seams follow upstream PR #1296. This fixture adds
// asynchronous label-removal states; it never runs launchctl or a provider.
private final class RemovingLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var clock: TimeInterval = 0
    private var loaded: Bool
    private var removingSince: TimeInterval?
    private var calls: [(arguments: [String], time: TimeInterval)] = []
    private var sleeps: [TimeInterval] = []
    var removalDelay: TimeInterval = 3
    var bootoutResponse: LaunchctlControl.Output?
    var printAfterBootout: LaunchctlControl.Output?
    var bootstrapResponse: LaunchctlControl.Output?
    var kickstartResponse: LaunchctlControl.Output?
    var failToSpawn: String?
    var failPrintAfterBootout = false
    var disabled = false

    init(loaded: Bool = true) { self.loaded = loaded }

    static let ok = LaunchctlControl.Output(status: 0, stdout: "", stderr: "")
    static func failure(_ text: String, status: Int32 = 1) -> LaunchctlControl.Output {
        .init(status: status, stdout: "", stderr: text)
    }
    static let absent = failure(
        "Could not find service \"io.darkbloom.provider\" in domain for user gui:501\n", status: 113)

    func now() -> TimeInterval { lock.withLock { clock } }
    func sleep(_ interval: TimeInterval) {
        lock.withLock { sleeps.append(interval); clock += interval }
    }
    func commands(_ verb: String) -> [[String]] {
        lock.withLock { calls.filter { $0.arguments.first == verb }.map(\.arguments) }
    }
    func commandTimes(_ verb: String) -> [TimeInterval] {
        lock.withLock { calls.filter { $0.arguments.first == verb }.map(\.time) }
    }
    var totalSleeps: Int { lock.withLock { sleeps.count } }
    var bootedOut: Bool { lock.withLock { calls.contains { $0.arguments.first == "bootout" } } }
    var exists: Bool {
        lock.withLock { present() }
    }
    private func present() -> Bool {
        if let removingSince, clock - removingSince >= removalDelay { return false }
        return loaded
    }
    func run(_ arguments: [String]) throws -> LaunchctlControl.Output {
        try lock.withLock {
            calls.append((arguments, clock))
            let verb = arguments.first ?? ""
            if failToSpawn == verb {
                throw NSError(domain: "Issue1102SyntheticSpawn", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "synthetic spawn failure: \(verb)"])
            }
            switch verb {
            case "print":
                if removingSince != nil {
                    if failPrintAfterBootout {
                        throw NSError(domain: "Issue1102SyntheticSpawn", code: 7,
                                      userInfo: [NSLocalizedDescriptionKey: "synthetic print spawn failure"])
                    }
                    if let printAfterBootout { return printAfterBootout }
                }
                return present() ? Self.ok : Self.absent
            case "disable": disabled = true; return Self.ok
            case "enable": disabled = false; return Self.ok
            case "bootout":
                if let bootoutResponse { return bootoutResponse }
                removingSince = clock
                return Self.ok
            case "bootstrap":
                if let bootstrapResponse { return bootstrapResponse }
                guard !present() else {
                    return Self.failure("Bootstrap failed: 5: Input/output error\n", status: 5)
                }
                loaded = true
                removingSince = nil
                return Self.ok
            case "kickstart":
                if let kickstartResponse { return kickstartResponse }
                return present() ? Self.ok : Self.failure("Could not kickstart service: 3: could not find service")
            default:
                throw NSError(domain: "Issue1102UnexpectedCommand", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "unexpected launchctl command: \(arguments)"])
            }
        }
    }
    func trace() -> [String: Any] {
        lock.withLock {
            ["virtual_seconds": clock, "sleep_intervals": sleeps, "disabled": disabled,
             "commands": calls.map { ["arguments": $0.arguments, "virtual_seconds": $0.time] }]
        }
    }
}

private func withRemovingLaunchd(
    _ id: String, _ launchd: RemovingLaunchd = RemovingLaunchd(),
    body: (URL, RemovingLaunchd) throws -> Void
) throws {
    let tempRoot = ProcessInfo.processInfo.environment["ISSUE1102_TEMP_ROOT"]
        .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let home = tempRoot.appendingPathComponent("issue1102-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer {
        if let path = ProcessInfo.processInfo.environment["ISSUE1102_TRACE_DIR"] {
            let trace = URL(fileURLWithPath: path).appendingPathComponent(id + ".json")
            if let data = try? JSONSerialization.data(withJSONObject: launchd.trace(), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: trace)
            }
        }
        try? FileManager.default.removeItem(at: home)
    }
    try LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
        try LaunchctlControl.$runnerForTesting.withValue({ try launchd.run($0) }) {
            try LaunchctlControl.$uptimeForTesting.withValue({ launchd.now() }) {
                try LaunchctlControl.$sleepForTesting.withValue({ launchd.sleep($0) }) {
                    #expect(LaunchAgent.plistPath().path.hasPrefix(home.path + "/"))
                    #expect(LaunchAgent.logPath().path.hasPrefix(home.path + "/"))
                    try body(home, launchd)
                }
            }
        }
    }
}

private func writeInstalledPlist() throws -> [String: Any] {
    let plist: [String: Any] = [
        "ProgramArguments": ["/fixture/darkbloom", "start", "--foreground", "--model", "chosen-model",
                             "--config", "/fixture/provider.toml"],
        "EnvironmentVariables": ["DARKBLOOM_PREFIX_CACHE": "0"],
        "RunAtLoad": true, "KeepAlive": false, "ExitTimeOut": 5
    ]
    try FileManager.default.createDirectory(at: LaunchAgent.plistPath().deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: LaunchAgent.plistPath())
    return plist
}
private func readPlist() throws -> [String: Any] {
    try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: LaunchAgent.plistPath()),
                                                         format: nil) as? [String: Any])
}
private func expectFailure(_ expected: String, operation: () throws -> Void) {
    do { try operation(); Issue.record("Expected failure containing: \(expected)") }
    catch { #expect(String(describing: error).localizedCaseInsensitiveContains(expected), "observed \(error)") }
}
private func expectNoReplacement(_ launchd: RemovingLaunchd) {
    #expect(launchd.commands("bootstrap").isEmpty)
    #expect(launchd.commands("kickstart").isEmpty)
}

@Suite("LaunchAgent asynchronous label removal")
struct LaunchAgentRemovalTests {
    @Test func installWaitsForDelayedRemoval() throws {
        try withRemovingLaunchd("1102-install-delayed-removal") { home, launchd in
            try LaunchAgent.installAndStart(
                coordinatorURL: "ws://127.0.0.1:1/ws/provider", models: ["model-a", "model-b"],
                configPath: home.appendingPathComponent("config.toml"),
                localEndpoint: .init(enabled: true, port: 9001, bind: "127.0.0.1", noAuth: false))
            #expect(launchd.commandTimes("bootstrap").count == 1)
            #expect(try #require(launchd.commandTimes("bootstrap").first) >= 3)
            #expect(launchd.commands("bootout").count == 1)
            #expect(launchd.commands("kickstart").count == 1)
            let args = try #require(readPlist()["ProgramArguments"] as? [String])
            #expect(Array(args.suffix(11)) == ["--config", home.appendingPathComponent("config.toml").path,
                "--model", "model-a", "--model", "model-b", "--local-endpoint", "--port", "9001", "--bind", "127.0.0.1"])
            #expect(!args.contains("--no-auth"))
        }
    }
    @Test func drainedRestartWaitsAndPreservesPlist() throws {
        try withRemovingLaunchd("1102-drained-restart-delayed-removal") { _, launchd in
            let original = try writeInstalledPlist()
            try LaunchAgent.restartAfterDrain()
            #expect(try #require(launchd.commandTimes("bootstrap").first) >= 3)
            #expect(launchd.commands("bootstrap").count == 1)
            #expect(launchd.commands("bootout").count == 1)
            let plist = try readPlist()
            #expect(plist["ProgramArguments"] as? [String] == original["ProgramArguments"] as? [String])
            #expect(plist["EnvironmentVariables"] as? [String: String] == original["EnvironmentVariables"] as? [String: String])
            #expect(plist["ExitTimeOut"] as? Int == 3660)
        }
    }
    @Test func stopThenInstallUsesCompletedRemoval() throws {
        try withRemovingLaunchd("1102-stop-then-install") { _, launchd in
            try LaunchAgent.stop()
            #expect(!launchd.exists)
            #expect(launchd.disabled)
            expectNoReplacement(launchd)
            try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider")
            #expect(launchd.commands("bootout").count == 1)
            #expect(launchd.commands("bootstrap").count == 1)
            #expect(!launchd.disabled)
        }
    }
    @Test func immediateRemovalDoesNotSleep() throws {
        let launchd = RemovingLaunchd(); launchd.removalDelay = 0
        try withRemovingLaunchd("1102-immediate-absence", launchd) { _, launchd in
            try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider")
            #expect(launchd.totalSleeps == 0)
            #expect(launchd.commands("bootstrap").count == 1)
        }
    }
    @Test func absentStopOnlyDisables() throws {
        try withRemovingLaunchd("1102-absent-stop", RemovingLaunchd(loaded: false)) { _, launchd in
            try LaunchAgent.stop()
            #expect(launchd.disabled)
            #expect(launchd.commands("bootout").isEmpty)
            #expect(launchd.totalSleeps == 0)
            expectNoReplacement(launchd)
        }
    }
    @Test func removalTimeoutDoesNotRewriteOrBootstrap() throws {
        let launchd = RemovingLaunchd(); launchd.removalDelay = .infinity
        try withRemovingLaunchd("1102-removal-timeout", launchd) { _, launchd in
            _ = try writeInstalledPlist()
            let original = try Data(contentsOf: LaunchAgent.plistPath())
            expectFailure("remov") {
                try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider", models: ["replacement"])
            }
            expectNoReplacement(launchd)
            #expect(launchd.now() >= 10 && launchd.now() <= 10.001)
            #expect(launchd.commands("print").count <= 102) // one initial query + at most101 removal probes
            #expect(try Data(contentsOf: LaunchAgent.plistPath()) == original)
        }
    }
    @Test(arguments: ["Operation not permitted", "unrecognized failure", "Could not find service \"io.darkbloom.provider.other\""])
    func printFailureIsNotAbsence(message: String) throws {
        let launchd = RemovingLaunchd(); launchd.printAfterBootout = RemovingLaunchd.failure(message, status: 113)
        let suffix = message.hasPrefix("Operation") ? "permission" : message.hasPrefix("unrecognized") ? "unknown" : "other-label"
        try withRemovingLaunchd("1102-print-errors-" + suffix, launchd) { _, launchd in
            expectFailure(message) { try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider") }
            expectNoReplacement(launchd)
        }
    }
    @Test func printSpawnFailurePropagates() throws {
        let launchd = RemovingLaunchd(); launchd.failPrintAfterBootout = true
        try withRemovingLaunchd("1102-print-spawn", launchd) { _, launchd in
            expectFailure("synthetic print spawn failure") { try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider") }
            expectNoReplacement(launchd)
        }
    }
    @Test func bootoutPermissionFailurePropagates() throws {
        let launchd = RemovingLaunchd(); launchd.bootoutResponse = RemovingLaunchd.failure("Boot-out failed: 150: Operation not permitted")
        try withRemovingLaunchd("1102-bootout-errors-permission", launchd) { _, launchd in
            expectFailure("Operation not permitted") { try LaunchAgent.stop() }
            #expect(launchd.disabled)
            #expect(launchd.commands("print").count == 1)
            expectNoReplacement(launchd)
        }
    }
    @Test func bootoutSpawnFailurePropagates() throws {
        let launchd = RemovingLaunchd(); launchd.failToSpawn = "bootout"
        try withRemovingLaunchd("1102-bootout-errors-spawn", launchd) { _, launchd in
            expectFailure("synthetic spawn failure") { try LaunchAgent.stop() }
            expectNoReplacement(launchd)
        }
    }
    @Test func bootoutAlreadyMissingStillConfirmsAbsence() throws {
        let launchd = RemovingLaunchd(); launchd.bootoutResponse = RemovingLaunchd.failure("Boot-out failed: 3: No such process")
        try withRemovingLaunchd("1102-bootout-already-missing", launchd) { _, launchd in
            // The initial query saw a loaded label. ESRCH from bootout alone must
            // not override a subsequent print which continues to show it loaded.
            expectFailure("remov") { try LaunchAgent.stop() }
            #expect(launchd.commands("print").count > 1)
            expectNoReplacement(launchd)
        }
    }
    @Test func inProgressBootstrapIsNotSuccess() throws {
        let launchd = RemovingLaunchd(loaded: false)
        launchd.bootstrapResponse = RemovingLaunchd.failure("Bootstrap failed: 37: Operation already in progress", status: 37)
        launchd.kickstartResponse = RemovingLaunchd.ok
        try withRemovingLaunchd("1102-bootstrap-in-progress", launchd) { _, launchd in
            expectFailure("37") { try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider") }
            #expect(launchd.commands("bootstrap").count == 1)
            #expect(launchd.commands("kickstart").isEmpty)
        }
    }
    @Test func explicitAlreadyLoadedCompatibilityRemains() throws {
        let launchd = RemovingLaunchd(loaded: false)
        launchd.bootstrapResponse = RemovingLaunchd.failure("Service is already loaded")
        launchd.kickstartResponse = RemovingLaunchd.ok
        try withRemovingLaunchd("1102-bootstrap-explicit-already-loaded", launchd) { _, launchd in
            try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider")
            #expect(launchd.commands("kickstart").count == 1)
        }
    }
    @Test(arguments: ["Bootstrap failed: 5: Input/output error", "Operation not permitted"])
    func unrelatedBootstrapFailurePropagates(message: String) throws {
        let launchd = RemovingLaunchd(loaded: false); launchd.bootstrapResponse = RemovingLaunchd.failure(message)
        try withRemovingLaunchd("1102-bootstrap-error-" + (message.hasPrefix("Bootstrap") ? "5" : "permission"), launchd) { _, launchd in
            expectFailure(message) { try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider") }
            #expect(launchd.commands("bootstrap").count == 1)
            #expect(launchd.commands("kickstart").isEmpty)
        }
    }
    @Test func bootstrapSpawnFailurePropagates() throws {
        let launchd = RemovingLaunchd(loaded: false); launchd.failToSpawn = "bootstrap"
        try withRemovingLaunchd("1102-bootstrap-spawn", launchd) { _, launchd in
            expectFailure("synthetic spawn failure") { try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider") }
            #expect(launchd.commands("kickstart").isEmpty)
        }
    }
    @Test func failedKickstartRemainsFailure() throws {
        let launchd = RemovingLaunchd(loaded: false); launchd.kickstartResponse = RemovingLaunchd.failure("kickstart refused")
        try withRemovingLaunchd("1102-kickstart-failure", launchd) { _, launchd in
            expectFailure("kickstart refused") { try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider") }
        }
    }
    @Test func stopWaitsAndNeverReloads() throws {
        try withRemovingLaunchd("1102-stop-and-uninstall-stop") { _, launchd in
            try LaunchAgent.stop()
            #expect(!launchd.exists)
            #expect(launchd.disabled)
            #expect(launchd.commands("enable").isEmpty)
            expectNoReplacement(launchd)
        }
    }
    @Test func uninstallWaitsBeforeRemovingPlist() throws {
        try withRemovingLaunchd("1102-stop-and-uninstall-success") { _, launchd in
            _ = try writeInstalledPlist()
            try LaunchAgent.uninstall()
            #expect(!launchd.exists)
            #expect(!LaunchAgent.isInstalled())
            expectNoReplacement(launchd)
        }
    }
    @Test func uninstallPreservesPlistOnRemovalFailure() throws {
        let launchd = RemovingLaunchd(); launchd.removalDelay = .infinity
        try withRemovingLaunchd("1102-stop-and-uninstall-failure", launchd) { _, launchd in
            _ = try writeInstalledPlist()
            expectFailure("remov") { try LaunchAgent.uninstall() }
            #expect(LaunchAgent.isInstalled())
            expectNoReplacement(launchd)
        }
    }
    @Test func loadedRestartStaysInPlace() throws {
        try withRemovingLaunchd("1102-restart-in-place") { _, launchd in
            try LaunchAgent.restart()
            #expect(launchd.commands("bootout").isEmpty)
            #expect(launchd.commands("bootstrap").isEmpty)
            #expect(launchd.commands("kickstart") == [["kickstart", "-k", LaunchctlControl.target(label: LaunchAgent.label)]])
        }
    }
    @Test func installedAbsentRestartLoads() throws {
        try withRemovingLaunchd("1102-restart-absent", RemovingLaunchd(loaded: false)) { _, launchd in
            _ = try writeInstalledPlist()
            try LaunchAgent.restart()
            #expect(launchd.commands("bootout").isEmpty)
            #expect(launchd.commands("bootstrap").count == 1)
        }
    }
    @Test func uninstalledRestartFails() throws {
        try withRemovingLaunchd("1102-restart-no-plist", RemovingLaunchd(loaded: false)) { _, launchd in
            expectFailure("not installed") { try LaunchAgent.restart() }
            expectNoReplacement(launchd)
        }
    }
    @Test func watchdogDoesNotResurrectAbsentService() throws {
        try withRemovingLaunchd("1102-watchdog-absent", RemovingLaunchd(loaded: false)) { _, launchd in
            let restarted = try LaunchAgent.kickstartIfLoaded()
            #expect(restarted == false)
            #expect(launchd.commands("enable").isEmpty)
            expectNoReplacement(launchd)
        }
    }
    @Test func watchdogLoadedKickstartsWithoutEnable() throws {
        try withRemovingLaunchd("1102-watchdog-loaded") { _, launchd in
            let restarted = try LaunchAgent.kickstartIfLoaded()
            #expect(restarted)
            #expect(launchd.commands("enable").isEmpty)
            #expect(launchd.commands("bootstrap").isEmpty)
            #expect(launchd.commands("kickstart").count == 1)
        }
    }
}
