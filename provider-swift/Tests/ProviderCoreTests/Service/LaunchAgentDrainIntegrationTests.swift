import Foundation
import Darwin
import Testing
@testable import ProviderCore

/// Opt-in real GUI-domain launchd test. The label, plist, script and log are
/// unique and temporary; it never operates on an installed provider/watchdog.
@Suite("Isolated launchd drain", .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LAUNCHD_TESTS"] == "1"))
struct LaunchAgentDrainIntegrationTests {
    @Test func bootoutAllowsTermHandlerToFinishAndDisablePreventsBootstrap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let label = "dev.darkbloom.lifecycle-test.\(UUID().uuidString.lowercased())"
        let target = LaunchctlControl.target(label: label)
        let script = root.appendingPathComponent("host.py")
        let started = root.appendingPathComponent("started")
        let drained = root.appendingPathComponent("drained")
        let plist = root.appendingPathComponent("test.plist")
        let log = root.appendingPathComponent("host.log")
        defer {
            _ = LaunchctlControl.run(["bootout", target])
            _ = LaunchctlControl.setEnabled(true, label: label)
            try? FileManager.default.removeItem(at: root)
        }
        let source = """
        import signal, sys, time, pathlib
        def stop(signum, frame):
            time.sleep(0.3)
            pathlib.Path(sys.argv[2]).write_text('terminal-written')
            sys.exit(0)
        signal.signal(signal.SIGTERM, stop)
        pathlib.Path(sys.argv[1]).write_text('running')
        while True: time.sleep(0.05)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let args = ["/usr/bin/python3", script.path, started.path, drained.path, "--model", "retained-model"]
        let dictionary = LaunchAgent.makeServicePlist(label: label, programArguments: args, logPath: log.path, environment: [:])
        #expect(dictionary["ExitTimeOut"] as? Int == 3660)
        #expect(dictionary["ProgramArguments"] as? [String] == args)
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: plist)
        let bootstrap = LaunchctlControl.run(["bootstrap", LaunchctlControl.guiDomain(), plist.path], captureStderr: true)
        try #require(bootstrap.succeeded, "isolated bootstrap: \(bootstrap.stderr)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: started.path))
        #expect(LaunchctlControl.setEnabled(false, label: label).succeeded)
        #expect(LaunchctlControl.run(["bootout", target], captureStderr: true).succeeded)
        while !FileManager.default.fileExists(atPath: drained.path), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect((try? String(contentsOf: drained, encoding: .utf8)) == "terminal-written")
        #expect(!LaunchctlControl.printSucceeds(label: label))
        #expect(!LaunchctlControl.run(["bootstrap", LaunchctlControl.guiDomain(), plist.path]).succeeded)
        #expect(!LaunchctlControl.printSucceeds(label: label))
    }
}


@Suite("Launchd drain allowance migration")
struct LaunchAgentDrainAllowanceTests {
    @Test func preservesEveryLaunchArgumentAndEnvironmentEntry() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        defer { try? FileManager.default.removeItem(at: path) }
        let original: [String: Any] = ["ProgramArguments": ["/custom/provider", "start", "--foreground", "--model", "chosen-model", "--config", "/custom/config.toml"], "EnvironmentVariables": ["DARKBLOOM_PREFIX_CACHE": "0"], "KeepAlive": false, "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: path)
        try LaunchAgent.refreshTerminationAllowance(at: path)
        let updated = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any])
        #expect(updated["ProgramArguments"] as? [String] == original["ProgramArguments"] as? [String])
        #expect(updated["EnvironmentVariables"] as? [String: String] == original["EnvironmentVariables"] as? [String: String])
        #expect(updated["ExitTimeOut"] as? Int == 3660)
    }
}
