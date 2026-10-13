import Foundation
import Testing

@testable import ProviderCore

/// The cluster service login agent (review finding 12) against a stateful
/// stand-in for launchd: install, idempotent re-install, restart of a parked
/// service, take-over of another install's job, and removal. No launchctl
/// process runs; the plist goes to a temp home folder.
private final class FakeLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loaded: Set<String> = []
    private(set) var disabled: Set<String> = []
    private(set) var calls: [[String]] = []
    /// What a bootstrap starts: whether the service then holds its lock.
    var serviceRunning = false
    private var clock: TimeInterval = 0

    var verbs: [String] { lock.withLock { calls.map { $0.first ?? "" } } }
    var uptime: TimeInterval { lock.withLock { clock } }
    func sleep(_ interval: TimeInterval) { lock.withLock { clock += interval } }
    func preload(_ label: String) { lock.withLock { _ = loaded.insert(label) } }
    func disable(_ label: String) { lock.withLock { _ = disabled.insert(label) } }
    func reset() { lock.withLock { calls = [] } }

    func run(_ arguments: [String]) throws -> LaunchctlControl.Output {
        lock.withLock {
            calls.append(arguments)
            func label(_ target: String) -> String { String(target.split(separator: "/").last ?? "") }
            switch arguments.first {
            case "print":
                return loaded.contains(label(arguments[1])) ? ok : .init(status: 113, stdout: "", stderr: "Could not find service")
            case "print-disabled":
                return .init(status: 0, stdout: "disabled services = {\n" + disabled.map { "\t\"\($0)\" => disabled\n" }.joined() + "}\n", stderr: "")
            case "enable": disabled.remove(label(arguments[1])); return ok
            case "disable": disabled.insert(label(arguments[1])); return ok
            case "bootstrap":
                let name = URL(fileURLWithPath: arguments[2]).deletingPathExtension().lastPathComponent
                if disabled.contains(name) { return .init(status: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error") }
                loaded.insert(name); serviceRunning = true
                return ok
            case "bootout":
                let name = label(arguments[1])
                guard loaded.remove(name) != nil else { return .init(status: 3, stdout: "", stderr: "Boot-out failed: 3: No such process") }
                serviceRunning = false
                return ok
            case "kickstart":
                guard loaded.contains(label(arguments.last ?? "")) else { return .init(status: 113, stdout: "", stderr: "Could not find service") }
                serviceRunning = true
                return ok
            default:
                return ok
            }
        }
    }
}

private let ok = LaunchctlControl.Output(status: 0, stdout: "", stderr: "")

private func withFakeLaunchd<T>(_ launchd: FakeLaunchd, _ body: (URL) throws -> T) throws -> T {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-agent-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    return try LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
        try LaunchctlControl.$runnerForTesting.withValue({ try launchd.run($0) }) {
            try LaunchctlControl.$uptimeForTesting.withValue({ launchd.uptime }) {
                try LaunchctlControl.$sleepForTesting.withValue({ launchd.sleep($0) }) { try body(home) }
            }
        }
    }
}

private let release = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"

private func job(_ executable: String = release, options: [String] = [], environment: [String: String] = [:]) throws -> ClusterServiceAgent.Job {
    try ClusterServiceAgent.job(executablePath: executable, serviceOptions: options,
                                logPath: URL(fileURLWithPath: "/h/.darkbloom/cluster-setup/service.log"), environment: environment)
}

@Suite("Cluster service login agent")
struct ClusterServiceAgentTests {
    @Test func theJobRunsTheSupervisorAtLoginWithTheServiceOptions() throws {
        let made = try job(options: ["--config", "/c/provider.toml"], environment: ["DARKBLOOM_PREFIX_CACHE": "0", "PATH": "/bin"])
        let plist = try #require(PropertyListSerialization.propertyList(from: made.plist, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == made.label)
        #expect(made.label == ClusterServiceAgentPlan.label(executablePath: release))
        #expect(plist["ProgramArguments"] as? [String] == [release, "cluster", "service", "--supervise", "--config", "/c/provider.toml"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(plist["EnvironmentVariables"] as? [String: String] == ["DARKBLOOM_PREFIX_CACHE": "0"],
                "the provider's allowlist only; PATH and the rest of the shell stay behind")
        #expect(try job(options: ["--config", "/c/provider.toml"], environment: ["DARKBLOOM_PREFIX_CACHE": "0"]).plist == made.plist,
                "the same inputs give the same bytes (an unchanged job is recognized)")
    }

    @Test func installIsIdempotentAndRestartsAParkedService() throws {
        let launchd = FakeLaunchd()
        try withFakeLaunchd(launchd) { home in
            let made = try job()
            let path = home.appendingPathComponent("Library/LaunchAgents/\(made.label).plist")
            var stopped = 0
            func install() throws -> ClusterServiceAgent.Outcome {
                try ClusterServiceAgent.install(made, serviceRunning: { launchd.serviceRunning }, stopUnsupervisedService: { stopped += 1 })
            }
            #expect(try install() == .installed)
            #expect(FileManager.default.fileExists(atPath: path.path))
            #expect(launchd.loaded == [made.label])
            #expect(!launchd.verbs.contains("enable"), "a job that was never disabled leaves no launchd override behind")

            launchd.reset()
            #expect(try install() == .unchanged, "running `darkbloom cluster` again changes nothing")
            #expect(!launchd.verbs.contains("bootstrap") && !launchd.verbs.contains("bootout") && !launchd.verbs.contains("kickstart"))

            launchd.serviceRunning = false  // parked after its restart budget
            launchd.reset()
            #expect(try install() == .restarted)
            #expect(launchd.verbs.contains("kickstart"))
            #expect(stopped == 0)
        }
    }

    @Test func aChangedJobIsReplacedAndAnotherInstallsJobGivesWay() throws {
        let launchd = FakeLaunchd()
        try withFakeLaunchd(launchd) { home in
            let development = try job("/w/.build/debug/darkbloom")
            _ = try ClusterServiceAgent.install(development, serviceRunning: { launchd.serviceRunning }, stopUnsupervisedService: {})
            let released = try job()
            #expect(try ClusterServiceAgent.install(released, serviceRunning: { launchd.serviceRunning }, stopUnsupervisedService: {})
                    == .installed)
            #expect(launchd.loaded == [released.label], "one cluster service per user: the other install's job was booted out")
            #expect(ClusterServiceAgent.installedLabels() == [released.label])

            let withConfig = try job(options: ["--config", "/c/provider.toml"])
            #expect(withConfig.label == released.label)
            #expect(try ClusterServiceAgent.install(withConfig, serviceRunning: { launchd.serviceRunning }, stopUnsupervisedService: {})
                    == .replaced)
            #expect(try Data(contentsOf: home.appendingPathComponent("Library/LaunchAgents/\(released.label).plist")) == withConfig.plist)
            #expect(launchd.loaded == [released.label])
        }
    }

    @Test func aServiceStartedOutsideLaunchdIsStoppedBeforeTheAgentLoads() throws {
        let launchd = FakeLaunchd()
        launchd.serviceRunning = true  // an earlier version's detached service holds the lock
        try withFakeLaunchd(launchd) { _ in
            var stopped = 0
            let made = try job()
            let outcome = try ClusterServiceAgent.install(made, serviceRunning: { launchd.serviceRunning },
                                                          stopUnsupervisedService: { stopped += 1; launchd.serviceRunning = false })
            #expect(outcome == .installed)
            #expect(stopped == 1)
            #expect(launchd.loaded == [made.label])
        }
    }

    @Test func aDisabledJobIsEnabledOnlyThen() throws {
        let launchd = FakeLaunchd()
        let made = try job()
        launchd.disable(made.label)
        try withFakeLaunchd(launchd) { _ in
            let outcome = try ClusterServiceAgent.install(made, serviceRunning: { launchd.serviceRunning }, stopUnsupervisedService: {})
            #expect(outcome == .installed)
            #expect(launchd.verbs.contains("enable"))
            #expect(launchd.loaded == [made.label])
        }
    }

    @Test func uninstallBootsOutAndDeletesEveryClusterServiceAgent() throws {
        let launchd = FakeLaunchd()
        try withFakeLaunchd(launchd) { home in
            let made = try job()
            _ = try ClusterServiceAgent.install(made, serviceRunning: { launchd.serviceRunning }, stopUnsupervisedService: {})
            // A stray file of another install, not loaded, and the provider's own agent, which is not ours.
            let agents = home.appendingPathComponent("Library/LaunchAgents")
            let stray = ClusterServiceAgentPlan.labelPrefix + "0123456789ab"
            try Data().write(to: agents.appendingPathComponent("\(stray).plist"))
            try Data().write(to: agents.appendingPathComponent("io.darkbloom.provider.plist"))
            let removed = try ClusterServiceAgent.uninstall(alsoLabel: made.label)
            #expect(Set(removed) == [made.label, stray])
            #expect(launchd.loaded.isEmpty)
            #expect(!launchd.verbs.contains("disable"), "removal deletes the job instead of leaving a launchd override")
            #expect(ClusterServiceAgent.installedLabels().isEmpty)
            #expect(FileManager.default.fileExists(atPath: agents.appendingPathComponent("io.darkbloom.provider.plist").path))
            #expect(try ClusterServiceAgent.uninstall().isEmpty, "removing twice is a no-op")
        }
    }

    @Test func aBootoutThatDoesNotFinishIsReportedAfterTheExitAllowance() throws {
        let launchd = FakeLaunchd()
        try withFakeLaunchd(launchd) { _ in
            let made = try job()
            _ = try ClusterServiceAgent.install(made, serviceRunning: { launchd.serviceRunning }, stopUnsupervisedService: {})
            // launchd keeps the job (its service is still releasing a part): bootout succeeds, print keeps finding it.
            let stuck = FakeLaunchd()
            stuck.preload(made.label)
            LaunchctlControl.$runnerForTesting.withValue({ arguments in
                arguments.first == "bootout" ? ok : try stuck.run(arguments)
            }) {
                #expect(throws: LaunchAgentError.self) { try ClusterServiceAgent.uninstall() }
            }
            #expect(launchd.uptime >= Double(ClusterServiceAgentPlan.exitTimeOutSeconds), "it waited the whole allowance")
        }
    }
}
