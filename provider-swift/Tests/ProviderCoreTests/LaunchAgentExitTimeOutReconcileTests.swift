// Copyright © 2026 Eigen Labs.
//
// `ExitTimeOut` on auto-updated installs: the plist is rewritten only by
// `darkbloom start`, and launchd re-reads it only at bootstrap (never on the
// `kickstart -k` the auto-update relaunch uses), so the fleet keeps launchd's
// 20 s default while the daemon believes it has 120 s. The daemon reads the
// loaded job's effective budget from `launchctl print`, clamps its drain
// below it, and reconciles the on-disk plist for the next bootstrap.

import Foundation
import Testing

@testable import ProviderCore

@Suite("LaunchAgent ExitTimeOut reconciliation")
struct LaunchAgentExitTimeOutReconcileTests {

    /// The shape `launchctl print gui/<uid>/<label>` emits (measured on
    /// macOS 26 with a throwaway label): `exit timeout = N` beside `runs`
    /// and `pid`.
    @Test("launchctl print's `exit timeout` is parsed into the launch snapshot")
    func parsesExitTimeout() {
        let output = """
        gui/501/io.darkbloom.provider = {
        \tactive count = 1
        \tpath = /Users/x/Library/LaunchAgents/io.darkbloom.provider.plist
        \tstate = running
        \tprogram = /Users/x/.darkbloom/bin/darkbloom
        \texit timeout = 20
        \truns = 3
        \tpid = 4242
        }
        """
        let snapshot = LaunchAgent.parseLaunchSnapshot(
            label: "io.darkbloom.provider", output: output, identityReader: { _ in nil })
        #expect(snapshot.exitTimeoutSeconds == 20)
        #expect(snapshot.runs == 3)
        let without = LaunchAgent.parseLaunchSnapshot(
            label: "io.darkbloom.provider", output: "state = running\nruns = 1\n",
            identityReader: { _ in nil })
        #expect(without.exitTimeoutSeconds == nil)
    }

    @Test("reconcile rewrites only a differing ExitTimeOut and keeps every other key")
    func reconcileRewritesDifferingValue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exit-timeout-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        // A pre-ExitTimeOut plist as an auto-updated box still has on disk.
        let original: [String: Any] = [
            "Label": "io.darkbloom.test",
            "ProgramArguments": ["/usr/local/bin/darkbloom", "start", "--foreground", "--model", "m"],
            "EnvironmentVariables": ["DARKBLOOM_PREFIX_CACHE": "0"],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
            .write(to: url)

        #expect(LaunchAgent.reconcileExitTimeOutOnDisk(at: url), "differing value was not rewritten")
        let rewritten = try #require(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(rewritten["ExitTimeOut"] as? Int == LaunchAgent.exitTimeOutSeconds)
        #expect(rewritten["ProgramArguments"] as? [String] == original["ProgramArguments"] as? [String])
        #expect(rewritten["EnvironmentVariables"] as? [String: String]
            == original["EnvironmentVariables"] as? [String: String])
        #expect(rewritten["RunAtLoad"] as? Bool == true)
        #expect(rewritten["Label"] as? String == "io.darkbloom.test")

        // Idempotent: a matching value is left alone.
        let before = try Data(contentsOf: url)
        #expect(!LaunchAgent.reconcileExitTimeOutOnDisk(at: url))
        #expect(try Data(contentsOf: url) == before)

        // Missing file: nothing to do, no throw.
        #expect(!LaunchAgent.reconcileExitTimeOutOnDisk(
            at: url.appendingPathExtension("missing")))
    }

    /// Until the next bootstrap an auto-updated box runs under launchd's
    /// 20 s default: the daemon's drain must end inside that, with the same
    /// close margin the plist value carries — never the full 120 s.
    @Test("the shutdown drain is clamped to the loaded job's ExitTimeOut minus the close margin")
    func drainClampsToLoadedExitTimeOut() {
        let margin = LaunchAgent.shutdownCloseMarginSeconds
        #expect(ProviderLoop.shutdownDrainBound(forLaunchdExitTimeOut: 20)
            == .seconds(20 - margin))
        // The intended value gives the full drain bound back.
        #expect(ProviderLoop.shutdownDrainBound(forLaunchdExitTimeOut: LaunchAgent.exitTimeOutSeconds)
            == ProviderLoop.gracefulDrainTimeout)
        // A larger operator-set budget never extends the drain past its own bound.
        #expect(ProviderLoop.shutdownDrainBound(forLaunchdExitTimeOut: 600)
            == ProviderLoop.gracefulDrainTimeout)
        // A budget smaller than the margin still leaves a floor.
        #expect(ProviderLoop.shutdownDrainBound(forLaunchdExitTimeOut: 3)
            == ProviderLoop.minimumShutdownDrainBound)
        #expect(ProviderLoop.minimumShutdownDrainBound > .zero)
    }

    @Test("a loop applies the clamp to its shutdown drain")
    func loopAppliesClamp() async throws {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "exit-timeout-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        let loop = try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
        #expect(await loop.shutdownDrainBoundForTesting() == ProviderLoop.gracefulDrainTimeout)
        await loop.clampShutdownDrain(toLaunchdExitTimeOut: 20)
        #expect(await loop.shutdownDrainBoundForTesting()
            == .seconds(20 - LaunchAgent.shutdownCloseMarginSeconds))
        // nil (not launchd-managed, or not reported): the default stands.
        await loop.clampShutdownDrain(toLaunchdExitTimeOut: nil)
        #expect(await loop.shutdownDrainBoundForTesting() == ProviderLoop.gracefulDrainTimeout)
    }
}
