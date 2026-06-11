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
        // APNs) with no human; KeepAlive stays false to avoid racing the self-updater.
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == false)
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
