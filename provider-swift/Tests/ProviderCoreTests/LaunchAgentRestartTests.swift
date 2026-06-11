import Foundation
import Testing
@testable import ProviderCore

/// Tests for the `LaunchAgent` restart error surface. The launchctl
/// kickstart/bootstrap behaviour itself is environment-dependent (it mutates a
/// real launchd domain) and is covered by manual verification; here we pin the
/// pure, deterministic pieces: the new error cases and their messages.
@Suite("LaunchAgent restart errors")
struct LaunchAgentRestartTests {

    @Test("notInstalled explains how to start the provider")
    func notInstalledDescription() {
        let message = LaunchAgentError.notInstalled.description
        #expect(message.contains("not installed"))
        #expect(message.contains("darkbloom start"))
    }

    @Test("kickstartFailed surfaces the underlying detail")
    func kickstartFailedDescription() {
        let message = LaunchAgentError.kickstartFailed("boom").description
        #expect(message.contains("kickstart"))
        #expect(message.contains("boom"))
    }
}

@Suite("LaunchAgent environment passthrough")
struct LaunchAgentEnvironmentTests {
    @Test func forwardsAllowlistedNonEmptyVars() {
        let env = ["DARKBLOOM_PREFIX_CACHE": "0", "PATH": "/usr/bin", "HOME": "/Users/x"]
        let out = LaunchAgent.passthroughEnvironment(from: env)
        // Only the allowlisted opt-out is forwarded to the daemon; PATH/HOME are not.
        #expect(out == ["DARKBLOOM_PREFIX_CACHE": "0"])
    }

    @Test func dropsEmptyAndMissingVars() {
        #expect(LaunchAgent.passthroughEnvironment(from: [:]).isEmpty)
        #expect(LaunchAgent.passthroughEnvironment(from: ["DARKBLOOM_PREFIX_CACHE": ""]).isEmpty)
    }
}

@Suite("LaunchAgent service plist")
struct LaunchAgentServicePlistTests {
    @Test func autoStartsAtLoadAndForwardsAllowlistedEnv() {
        let plist = LaunchAgent.makeServicePlist(
            label: "io.darkbloom.provider",
            programArguments: ["/usr/local/bin/darkbloom", "start", "--foreground"],
            logPath: "/tmp/p.log",
            environment: ["DARKBLOOM_PREFIX_CACHE": "0", "PATH": "/usr/bin"]
        )
        // RunAtLoad=true so a rebooted / auto-login box restarts (and re-attests via
        // APNs) with no human.
        #expect(plist["RunAtLoad"] as? Bool == true)
        // KeepAlive restarts ONLY on abnormal exit (crash/OOM-kill) — crash
        // recovery without racing the self-updater. Clean bootout (stop) and
        // kickstart (update) are unaffected. Must be the dict form
        // {SuccessfulExit: false}, NOT the old unconditional `false`.
        let keepAlive = plist["KeepAlive"] as? [String: Bool]
        #expect(keepAlive == ["SuccessfulExit": false])
        #expect(plist["KeepAlive"] as? Bool == nil)
        #expect((plist["EnvironmentVariables"] as? [String: String]) == ["DARKBLOOM_PREFIX_CACHE": "0"])
    }

    @Test func omitsEnvironmentWhenNoAllowlistedVarsSet() {
        let plist = LaunchAgent.makeServicePlist(
            label: "io.darkbloom.provider",
            programArguments: ["darkbloom", "start", "--foreground"],
            logPath: "/tmp/p.log",
            environment: ["PATH": "/usr/bin"]
        )
        #expect(plist["EnvironmentVariables"] == nil)
        #expect(plist["RunAtLoad"] as? Bool == true)
    }
}

@Suite("LaunchAgent KeepAlive policy refresh")
struct LaunchAgentKeepAliveSyncTests {
    private func writePlist(_ dict: [String: Any]) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ka-sync-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: path)
        return path
    }

    /// An old-fleet plist (KeepAlive=false bool) is upgraded in place to the
    /// crash-recovery dict, preserving every other key — this is the only
    /// channel by which existing installs ever gain crash recovery (auto-update
    /// restarts never re-read the plist).
    @Test func upgradesLegacyBoolKeepAlivePreservingOtherKeys() throws {
        let path = try writePlist([
            "Label": "io.darkbloom.provider",
            "ProgramArguments": ["/Users/op/.darkbloom/bin/darkbloom", "start", "--foreground"],
            "KeepAlive": false,
            "RunAtLoad": true,
            "EnvironmentVariables": ["DARKBLOOM_PREFIX_CACHE": "0"],
        ])
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(try LaunchAgent.syncKeepAlivePolicy(at: path) == true)

        let data = try Data(contentsOf: path)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        #expect((plist?["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        // Operator customizations survive the surgical rewrite.
        #expect((plist?["ProgramArguments"] as? [String])?.count == 3)
        #expect((plist?["EnvironmentVariables"] as? [String: String]) == ["DARKBLOOM_PREFIX_CACHE": "0"])
        #expect(plist?["RunAtLoad"] as? Bool == true)
    }

    @Test func alreadyCurrentAndMissingAreNoOps() throws {
        let current = try writePlist([
            "Label": "io.darkbloom.provider",
            "KeepAlive": ["SuccessfulExit": false],
        ])
        defer { try? FileManager.default.removeItem(at: current) }
        #expect(try LaunchAgent.syncKeepAlivePolicy(at: current) == false)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ka-sync-missing-\(UUID().uuidString).plist")
        #expect(try LaunchAgent.syncKeepAlivePolicy(at: missing) == false)
    }
}
