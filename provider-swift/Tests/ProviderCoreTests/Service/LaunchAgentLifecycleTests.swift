import Foundation
import Testing

@testable import ProviderCore

/// `LaunchAgent` install, stop, restart and uninstall against a scripted
/// launchctl. Each test binds the task-local seams in `LaunchctlControl`:
/// no launchctl process runs and the plist goes to a temp home folder.

/// Answers launchctl calls by verb and records every call.
private final class ScriptedLaunchctl: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var answers: [String: [LaunchctlControl.Output]] = [:]
    private var spawnFailures: Set<String> = []

    /// Queue answers for one verb. The last answer repeats.
    func answer(_ verb: String, _ outputs: LaunchctlControl.Output...) {
        lock.withLock { answers[verb] = outputs }
    }

    /// Make every call for this verb fail to start, like a missing binary.
    func failToSpawn(_ verb: String) {
        lock.withLock { _ = spawnFailures.insert(verb) }
    }

    var recorded: [[String]] { lock.withLock { calls } }
    var verbs: [String] { recorded.map { $0.first ?? "" } }

    func run(_ arguments: [String]) throws -> LaunchctlControl.Output {
        try lock.withLock {
            calls.append(arguments)
            let verb = arguments.first ?? ""
            if spawnFailures.contains(verb) {
                throw CocoaError(.executableNotLoadable)
            }
            guard var queue = answers[verb], let first = queue.first else {
                return ok
            }
            if queue.count > 1 {
                queue.removeFirst()
                answers[verb] = queue
            }
            return first
        }
    }
}

private let ok = LaunchctlControl.Output(status: 0, stdout: "", stderr: "")

private func failure(_ stderr: String, status: Int32 = 1) -> LaunchctlControl.Output {
    LaunchctlControl.Output(status: status, stdout: "", stderr: stderr)
}

/// Run `body` with the scripted launchctl and a temp home folder bound.
private func withScriptedLaunchd<T>(
    _ launchctl: ScriptedLaunchctl,
    _ body: (URL) throws -> T
) throws -> T {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("launch-agent-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    return try LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
        try LaunchctlControl.$runnerForTesting.withValue({ try launchctl.run($0) }) {
            try body(home)
        }
    }
}

private func writeInstalledPlist(home: URL) throws -> URL {
    let path = home.appendingPathComponent("Library/LaunchAgents/io.darkbloom.provider.plist")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "Label": LaunchAgent.label,
        "ProgramArguments": ["/opt/darkbloom", "start", "--foreground"],
        "ExitTimeOut": 30,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: path)
    return path
}

private func readPlist(_ path: URL) throws -> [String: Any] {
    try #require(
        PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil)
            as? [String: Any])
}

private let serviceTarget = LaunchctlControl.target(label: LaunchAgent.label)

@Suite("LaunchAgent lifecycle with scripted launchctl")
struct LaunchAgentLifecycleTests {

    // MARK: Paths

    @Test("plist and log paths follow the bound home folder")
    func pathsFollowHome() throws {
        let launchctl = ScriptedLaunchctl()
        try withScriptedLaunchd(launchctl) { home in
            #expect(LaunchAgent.plistPath().path
                == home.appendingPathComponent("Library/LaunchAgents/io.darkbloom.provider.plist").path)
            #expect(LaunchAgent.logPath().path
                == home.appendingPathComponent(".darkbloom/provider.log").path)
            #expect(!LaunchAgent.isInstalled())
            _ = try writeInstalledPlist(home: home)
            #expect(LaunchAgent.isInstalled())
        }
        #expect(launchctl.recorded.isEmpty)
    }

    @Test("isLoaded is the exit status of launchctl print for the service")
    func isLoadedUsesPrint() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("Could not find service"), ok)
        try withScriptedLaunchd(launchctl) { _ in
            #expect(!LaunchAgent.isLoaded())
            #expect(LaunchAgent.isLoaded())
        }
        #expect(launchctl.recorded == [["print", serviceTarget], ["print", serviceTarget]])
    }

    // MARK: Install

    @Test("install writes the plist, then enables, bootstraps and kickstarts the service")
    func installWritesPlistAndLoads() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("Could not find service"))
        let config = URL(fileURLWithPath: "/tmp/provider-test.toml")
        let plistPath = try withScriptedLaunchd(launchctl) { home -> String in
            try LaunchAgent.installAndStart(
                coordinatorURL: "ws://127.0.0.1:1/ws/provider",
                models: ["org/model-a", "org/model-b"],
                configPath: config,
                localEndpoint: .init(enabled: true, port: 8123, bind: "127.0.0.1", noAuth: true)
            )

            let plist = try readPlist(LaunchAgent.plistPath())
            #expect(plist["Label"] as? String == LaunchAgent.label)
            #expect(plist["RunAtLoad"] as? Bool == true)
            #expect(plist["KeepAlive"] as? Bool == false)
            #expect(plist["ExitTimeOut"] as? Int == 3660)
            #expect(plist["StandardOutPath"] as? String
                == home.appendingPathComponent(".darkbloom/provider.log").path)
            let arguments = try #require(plist["ProgramArguments"] as? [String])
            #expect(Array(arguments.dropFirst()) == [
                "start", "--foreground",
                "--coordinator-url", "ws://127.0.0.1:1/ws/provider",
                "--config", config.standardizedFileURL.path,
                "--model", "org/model-a",
                "--model", "org/model-b",
                "--local-endpoint", "--port", "8123", "--bind", "127.0.0.1", "--no-auth",
            ])
            return LaunchAgent.plistPath().path
        }
        #expect(launchctl.recorded == [
            ["print", serviceTarget],
            ["enable", serviceTarget],
            ["bootstrap", LaunchctlControl.guiDomain(), plistPath],
            ["kickstart", serviceTarget],
        ])
    }

    @Test("install unloads a loaded service first so the new plist takes effect")
    func installUnloadsLoadedService() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider")
            #expect(LaunchAgent.isInstalled())
        }
        #expect(launchctl.verbs == ["print", "bootout", "enable", "bootstrap", "kickstart"])
    }

    @Test("bootstrap that reports already loaded is not an error")
    func bootstrapAlreadyLoadedIsTolerated() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        launchctl.answer("bootstrap", failure("Bootstrap failed: 37: Operation already in progress"))
        try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider")
        }
        #expect(launchctl.verbs == ["print", "enable", "bootstrap", "kickstart"])
    }

    @Test("any other bootstrap failure is thrown with the trimmed launchctl text")
    func bootstrapFailureThrows() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        launchctl.answer("bootstrap", failure("Bootstrap failed: 5: Input/output error\n"))
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider")
                Issue.record("expected bootstrapFailed")
            } catch let error as LaunchAgentError {
                guard case .bootstrapFailed(let detail) = error else {
                    Issue.record("expected bootstrapFailed, got \(error)")
                    return
                }
                #expect(detail == "Bootstrap failed: 5: Input/output error")
            }
        }
        #expect(!launchctl.verbs.contains("kickstart"))
    }

    @Test("a failed kickstart after bootstrap is thrown")
    func kickstartFailureAfterBootstrapThrows() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        launchctl.answer("kickstart", failure("kickstart refused\n"))
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider")
                Issue.record("expected kickstartFailed")
            } catch let error as LaunchAgentError {
                guard case .kickstartFailed(let detail) = error else {
                    Issue.record("expected kickstartFailed, got \(error)")
                    return
                }
                #expect(detail == "kickstart refused")
            }
        }
    }

    @Test("a kickstart that cannot start launchctl is thrown as a kickstart failure")
    func kickstartSpawnFailureThrows() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        launchctl.failToSpawn("kickstart")
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.installAndStart(coordinatorURL: "ws://127.0.0.1:1/ws/provider")
                Issue.record("expected kickstartFailed")
            } catch let error as LaunchAgentError {
                guard case .kickstartFailed(let detail) = error else {
                    Issue.record("expected kickstartFailed, got \(error)")
                    return
                }
                #expect(detail.hasPrefix("could not run launchctl kickstart:"))
            }
        }
    }

    // MARK: Stop

    @Test("stop disables the service and boots out a loaded one")
    func stopDisablesAndBootsOut() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.stop()
        }
        #expect(launchctl.recorded == [
            ["disable", serviceTarget],
            ["print", serviceTarget],
            ["bootout", serviceTarget],
        ])
    }

    @Test("stop of a service that is not loaded only disables it")
    func stopNotLoadedOnlyDisables() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.stop()
        }
        #expect(launchctl.verbs == ["disable", "print"])
    }

    @Test("a failed disable is thrown before any bootout")
    func stopDisableFailureThrows() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("disable", failure(" not permitted \n"))
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.stop()
                Issue.record("expected disableFailed")
            } catch let error as LaunchAgentError {
                guard case .disableFailed(let detail) = error else {
                    Issue.record("expected disableFailed, got \(error)")
                    return
                }
                #expect(detail == "not permitted")
            }
        }
        #expect(launchctl.verbs == ["disable"])
    }

    @Test("bootout of a service that is already gone is not an error")
    func bootoutMissingServiceIsTolerated() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        launchctl.answer("bootout", failure("Boot-out failed: 3: No such process"))
        try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.stop()
        }
        #expect(launchctl.verbs == ["disable", "print", "bootout"])
    }

    @Test("any other bootout failure is thrown")
    func bootoutFailureThrows() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        launchctl.answer("bootout", failure("Boot-out failed: 150: Operation not permitted\n"))
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.stop()
                Issue.record("expected bootoutFailed")
            } catch let error as LaunchAgentError {
                guard case .bootoutFailed(let detail) = error else {
                    Issue.record("expected bootoutFailed, got \(error)")
                    return
                }
                #expect(detail == "Boot-out failed: 150: Operation not permitted")
            }
        }
    }

    // MARK: Restart

    @Test("restart of a loaded service enables it and kickstarts with kill")
    func restartLoadedKickstarts() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.restart()
        }
        #expect(launchctl.recorded == [
            ["print", serviceTarget],
            ["enable", serviceTarget],
            ["kickstart", "-k", serviceTarget],
        ])
    }

    @Test("restart reloads a service that vanished between the check and the kickstart")
    func restartReloadsVanishedService() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        launchctl.answer(
            "kickstart",
            failure("Could not kickstart service: 3: could not find service"),
            ok)
        try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.restart()
        }
        #expect(launchctl.verbs == ["print", "enable", "kickstart", "enable", "bootstrap", "kickstart"])
    }

    @Test("restart throws when the enable step fails")
    func restartEnableFailureThrows() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        launchctl.answer("enable", failure("enable refused"))
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.restart()
                Issue.record("expected kickstartFailed")
            } catch let error as LaunchAgentError {
                guard case .kickstartFailed(let detail) = error else {
                    Issue.record("expected kickstartFailed, got \(error)")
                    return
                }
                #expect(detail == "enable refused")
            }
        }
        #expect(!launchctl.verbs.contains("kickstart"))
    }

    @Test("restart throws any other kickstart failure")
    func restartKickstartFailureThrows() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        launchctl.answer("kickstart", failure("Could not kickstart service: 1: Operation not permitted\n"))
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.restart()
                Issue.record("expected kickstartFailed")
            } catch let error as LaunchAgentError {
                guard case .kickstartFailed(let detail) = error else {
                    Issue.record("expected kickstartFailed, got \(error)")
                    return
                }
                #expect(detail == "Could not kickstart service: 1: Operation not permitted")
            }
        }
    }

    @Test("restart of an installed but unloaded service loads it")
    func restartInstalledLoads() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        try withScriptedLaunchd(launchctl) { home in
            _ = try writeInstalledPlist(home: home)
            try LaunchAgent.restart()
        }
        #expect(launchctl.verbs == ["print", "enable", "bootstrap", "kickstart"])
    }

    @Test("restart with no plist and no loaded service throws not installed")
    func restartNothingThrowsNotInstalled() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.restart()
                Issue.record("expected notInstalled")
            } catch let error as LaunchAgentError {
                guard case .notInstalled = error else {
                    Issue.record("expected notInstalled, got \(error)")
                    return
                }
            }
        }
        #expect(launchctl.verbs == ["print"])
    }

    // MARK: Restart after drain

    @Test("restart after drain needs an installed plist")
    func restartAfterDrainNeedsPlist() throws {
        let launchctl = ScriptedLaunchctl()
        try withScriptedLaunchd(launchctl) { _ in
            do {
                try LaunchAgent.restartAfterDrain()
                Issue.record("expected notInstalled")
            } catch let error as LaunchAgentError {
                guard case .notInstalled = error else {
                    Issue.record("expected notInstalled, got \(error)")
                    return
                }
            }
        }
        #expect(launchctl.recorded.isEmpty)
    }

    @Test("restart after drain raises the exit allowance, boots out and loads again")
    func restartAfterDrainReloads() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        try withScriptedLaunchd(launchctl) { home in
            let path = try writeInstalledPlist(home: home)
            try LaunchAgent.restartAfterDrain()
            let plist = try readPlist(path)
            #expect(plist["ExitTimeOut"] as? Int == 3660)
            #expect(plist["ProgramArguments"] as? [String] == ["/opt/darkbloom", "start", "--foreground"])
        }
        #expect(launchctl.verbs == ["print", "bootout", "enable", "bootstrap", "kickstart"])
    }

    // MARK: Watchdog kickstart

    @Test("kickstartIfLoaded does nothing for a service that is not loaded")
    func kickstartIfLoadedSkipsUnloaded() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        let kicked = try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.kickstartIfLoaded()
        }
        #expect(!kicked)
        #expect(launchctl.verbs == ["print"])
    }

    @Test("kickstartIfLoaded kills and relaunches without enabling the service")
    func kickstartIfLoadedKickstarts() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        let kicked = try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.kickstartIfLoaded()
        }
        #expect(kicked)
        #expect(launchctl.recorded == [["print", serviceTarget], ["kickstart", "-k", serviceTarget]])
    }

    @Test("kickstartIfLoaded never reloads a service that vanished")
    func kickstartIfLoadedNeverReloads() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        launchctl.answer("kickstart", failure("3: could not find service"))
        let kicked = try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.kickstartIfLoaded()
        }
        #expect(kicked)
        #expect(launchctl.verbs == ["print", "kickstart"])
    }

    // MARK: Uninstall

    @Test("uninstall stops the service and removes the plist")
    func uninstallRemovesPlist() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", ok)
        try withScriptedLaunchd(launchctl) { home in
            let path = try writeInstalledPlist(home: home)
            try LaunchAgent.uninstall()
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(!LaunchAgent.isInstalled())
        }
        #expect(launchctl.verbs == ["disable", "print", "bootout"])
    }

    @Test("uninstall with no plist only stops the service")
    func uninstallWithoutPlist() throws {
        let launchctl = ScriptedLaunchctl()
        launchctl.answer("print", failure("not loaded"))
        try withScriptedLaunchd(launchctl) { _ in
            try LaunchAgent.uninstall()
        }
        #expect(launchctl.verbs == ["disable", "print"])
    }
}
