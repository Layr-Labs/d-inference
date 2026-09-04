// Copyright © 2026 Eigen Labs.
//
// T1-13 (3)/(4) — per-request environment materialization and the daemon
// state path are resolved once per process; the memory-cap resolvers keep
// their explicit `env:` parameters for tests.

import Foundation
import Testing

@testable import ProviderCore

@Suite("Process environment snapshot (T1-13)")
struct ProcessEnvironmentSnapshotTests {

    @Test("the memory-cap resolvers read the same values from the snapshot as from a live environment read")
    func snapshotMatchesLiveEnvironment() {
        let live = ProcessInfo.processInfo.environment
        #expect(UnifiedMemoryCap.liveEnvironment["DARKBLOOM_MEM_CAP_FRACTION"]
            == live["DARKBLOOM_MEM_CAP_FRACTION"])
        #expect(UnifiedMemoryCap.liveEnvironment["DARKBLOOM_ACTIVATION_RESERVE_GB"]
            == live["DARKBLOOM_ACTIVATION_RESERVE_GB"])
        #expect(UnifiedMemoryCap.resolvedCapFraction(explicit: nil)
            == UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: live))
        #expect(UnifiedMemoryCap.resolvedActivationReserveBytes()
            == UnifiedMemoryCap.resolvedActivationReserveBytes(env: live))
        #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: ["x/unmeasured"])
            == UnifiedMemoryCap.resolvedActivationReserveBytes(env: live, modelIDs: ["x/unmeasured"]))
    }

    @Test("explicit env parameters still override the snapshot")
    func explicitEnvStillWins() {
        #expect(UnifiedMemoryCap.resolvedCapFraction(
            explicit: nil, env: ["DARKBLOOM_MEM_CAP_FRACTION": "0.5"]) == 0.5)
        let raised = UnifiedMemoryCap.resolvedActivationReserveBytes(
            env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "64"])
        #expect(raised == 64 * 1_073_741_824)
    }

    @Test("the daemon state path is resolved once and is stable")
    func daemonStatePathIsStable() {
        let first = DaemonStateFile.path()
        let second = DaemonStateFile.path()
        #expect(first == second)
        let live = ProcessInfo.processInfo.environment["DARKBLOOM_STATE_FILE"]
        if let live, !live.isEmpty {
            #expect(first == URL(fileURLWithPath: live))
        } else {
            #expect(first.lastPathComponent == "daemon-state.json")
        }
    }
}
