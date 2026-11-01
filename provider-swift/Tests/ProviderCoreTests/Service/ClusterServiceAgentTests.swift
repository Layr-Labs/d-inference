import Foundation
import Testing

@testable import ProviderCore
import DarkbloomClusterSecurity

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

private func withAgentApp<T>(_ body: (URL, URL, URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-agent-app-\(UUID().uuidString)")
    let contents = root.appendingPathComponent("Fixture.app/Contents")
    let executable = contents.appendingPathComponent("MacOS/fixture-provider")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: executable)
    return try body(root, executable, contents.appendingPathComponent("Info.plist"))
}

@Suite("Cluster service login agent")
struct ClusterServiceAgentTests {
    @Test func thePlanAssociatesOnlyTheSuppliedNonemptyBundleIdentifier() {
        let legacy = ClusterServiceAgentPlan.propertyList(label: "fixture-agent", programArguments: ["/fixture/provider"],
            logPath: "/fixture/service.log", environment: [:])
        #expect(legacy["AssociatedBundleIdentifiers"] == nil)
        func plan(_ identifier: String? = nil) -> [String: Any] {
            ClusterServiceAgentPlan.propertyList(label: "fixture-agent", programArguments: ["/fixture/provider"],
                logPath: "/fixture/service.log", environment: [:], bundleIdentifier: identifier)
        }
        #expect(plan()["AssociatedBundleIdentifiers"] == nil)
        #expect(plan("")["AssociatedBundleIdentifiers"] == nil)
        #expect(plan(" \n")["AssociatedBundleIdentifiers"] == nil)
        #expect(plan("example.fixture.provider")["AssociatedBundleIdentifiers"] as? [String] == ["example.fixture.provider"])
    }

    @Test func theJobUsesItsEnclosingAppsIdentityAndReplacesAnOlderUnassociatedJob() throws {
        try withAgentApp { root, executable, infoPath in
            let info = ["CFBundleIdentifier": "example.fixture.provider", "CFBundleExecutable": executable.lastPathComponent]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoPath)
            let made = try job(executable.path)
            let plist = try #require(PropertyListSerialization.propertyList(from: made.plist, format: nil) as? [String: Any])
            #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["example.fixture.provider"],
                    "read the synthetic app's identity, not the test runner's or a product constant")
            #expect(plist["ProgramArguments"] as? [String] == [executable.path, "cluster", "service", "--supervise"])
            #expect(try job(executable.path).plist == made.plist)

            // A symlinked CLI belongs to its real enclosing app.
            let alias = root.appendingPathComponent("provider-link")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
            let linked = try job(alias.path)
            let linkedPlist = try #require(PropertyListSerialization.propertyList(from: linked.plist, format: nil) as? [String: Any])
            #expect(linkedPlist["AssociatedBundleIdentifiers"] as? [String] == ["example.fixture.provider"])

            // The migration must reach the installer: identical label/options,
            // but the old bytes lack the association, so reload exactly once.
            var old = plist
            old["AssociatedBundleIdentifiers"] = nil
            let oldBytes = try ClusterServiceAgentPlan.encoded(old)
            let launchd = FakeLaunchd()
            try withFakeLaunchd(launchd) { home in
                let path = home.appendingPathComponent("Library/LaunchAgents/\(made.label).plist")
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try oldBytes.write(to: path)
                launchd.preload(made.label)
                launchd.serviceRunning = true
                #expect(try ClusterServiceAgent.install(made, serviceRunning: { launchd.serviceRunning },
                                                       stopUnsupervisedService: {}) == .replaced)
                #expect(launchd.verbs.contains("bootout") && launchd.verbs.contains("bootstrap"))
                #expect(try Data(contentsOf: path) == made.plist)
                launchd.reset()
                #expect(try ClusterServiceAgent.install(made, serviceRunning: { launchd.serviceRunning },
                                                       stopUnsupervisedService: {}) == .unchanged)
                #expect(!launchd.verbs.contains("bootout") && !launchd.verbs.contains("bootstrap"))
            }
        }
    }

    @Test func theJobOmitsAssociationWithoutAnEnclosingMainAppIdentity() throws {
        try withAgentApp { root, executable, infoPath in
            func expectUnassociated(_ path: String) throws {
                let made = try job(path)
                let plist = try #require(PropertyListSerialization.propertyList(from: made.plist, format: nil) as? [String: Any])
                #expect(plist["AssociatedBundleIdentifiers"] == nil)
            }
            try expectUnassociated(executable.path) // missing Info.plist
            try Data("invalid plist".utf8).write(to: infoPath)
            try expectUnassociated(executable.path)
            let invalidIdentities: [[String: Any]] = [
                ["CFBundleExecutable": executable.lastPathComponent],
                ["CFBundleExecutable": executable.lastPathComponent, "CFBundleIdentifier": ""],
                ["CFBundleExecutable": executable.lastPathComponent, "CFBundleIdentifier": " \n"],
                ["CFBundleExecutable": executable.lastPathComponent, "CFBundleIdentifier": 7],
                ["CFBundleExecutable": "another-program", "CFBundleIdentifier": "example.unrelated.app"],
            ]
            for info in invalidIdentities {
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoPath)
                try expectUnassociated(executable.path)
            }

            let valid = ["CFBundleExecutable": executable.lastPathComponent, "CFBundleIdentifier": "example.fixture.provider"]
            try PropertyListSerialization.data(fromPropertyList: valid, format: .xml, options: 0).write(to: infoPath)
            let outside = root.appendingPathComponent(executable.lastPathComponent)
            try Data().write(to: outside)
            try expectUnassociated(outside.path) // a nearby app is not the tool's responsible app
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: outside)
            try expectUnassociated(executable.path) // a bundle-shaped alias cannot claim an external tool
        }
    }

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

    /// `cluster pair --forget` removes the agent only when this Mac holds no
    /// pairing any more; a store it cannot read is never taken for "unpaired".
    @Test func onlyAnEmptyOrAbsentPairingStoreCountsAsUnpaired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unpaired-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClusterPairingStore(directory: root.appendingPathComponent("cluster-pairing"))
        #expect(ClusterService.holdsNoPairing(store: store), "nothing was ever paired here")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #expect(ClusterService.holdsNoPairing(store: store), "an empty store")
        try Data("{}".utf8).write(to: store.recordsFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.recordsFile.path)
        #expect(!ClusterService.holdsNoPairing(store: store), "a malformed store is not unpaired")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.recordsFile.path)
        #expect(!ClusterService.holdsNoPairing(store: store), "a store refused for its mode is not unpaired")
    }
}
