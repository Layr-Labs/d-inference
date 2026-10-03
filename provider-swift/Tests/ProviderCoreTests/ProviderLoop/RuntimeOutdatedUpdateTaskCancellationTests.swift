// Contract under test: the tracked update-check task ProviderLoop starts
// from a coordinator-triggered runtime-outdated event.
//
// `handleRuntimeOutdatedEvent(mismatches:)` records the mismatch and, when
// due, starts an update check as a tracked task:
//
//     internal var runtimeOutdatedUpdateTask: Task<Void, Never>?
//
// Both teardown sites cancel it alongside the existing `autoUpdateTask`:
// the coordinator event-loop teardown in `ProviderLoop+Serve.swift`, and
// `performLifecycleDrain` (reached through the public
// `drainForLifecycle(request:)`, exercised below -- the smallest seam that
// needs no live coordinator connection; see
// `Tests/ProviderCoreTests/Service/ProviderLifecycleTests.swift` for the
// same pattern used elsewhere). There is no equivalent lightweight seam in
// this test target for the `ProviderLoop+Serve.swift` teardown site, which
// only runs after a real (or fully faked) coordinator connection's event
// stream ends, so this file exercises only the `drainForLifecycle` site.
//
// A second trigger must not start or stamp a new task while a previously
// tracked one is still outstanding: the guard is expected to check
// `runtimeOutdatedUpdateTask` itself, not just the 10-minute spacing gate,
// and the task is expected to clear its own tracked handle on exit so a
// later trigger (after the previous one has actually finished) can fire
// again.

import Foundation
import Testing
@testable import ProviderCore

@Suite("ProviderLoop runtime-outdated update task cancellation")
struct RuntimeOutdatedUpdateTaskCancellationTests {
    private func makeLoop() throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            // Unconnectable on purpose -- see RuntimeIntegrityStateTests.swift.
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], config: ProviderConfig(
                provider: ProviderSettings(name: "runtime-outdated-task-test", autoUpdate: true),
                backend: BackendSettings(), coordinator: CoordinatorSettings()))
        return try ProviderLoop(config: config, attestationSigner: nil)
    }

    @Test("drainForLifecycle cancels the armed runtime-outdated update task")
    func drainForLifecycleCancelsRuntimeOutdatedUpdateTask() async throws {
        let loop = try makeLoop()
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.setDaemonStateFileForTesting(stateURL)

        // Arm runtimeOutdatedUpdateTask the real way: through the event
        // path a coordinator dispatch uses.
        await loop.handleRuntimeOutdatedEvent(mismatches: [
            RuntimeMismatch(component: "binary_hash", expected: "aaa", got: "bbb"),
        ])
        let armed = try #require(
            await loop.runtimeOutdatedUpdateTask,
            "test setup: expected handleRuntimeOutdatedEvent to have armed a task")

        let identity = try #require(ProcessIdentity.current())
        _ = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 1))

        #expect(armed.isCancelled)
    }

    @Test("a second trigger does not replace or re-stamp a still-tracked task; drain still cancels the original")
    func secondTriggerDoesNotReplaceStillTrackedTask() async throws {
        let loop = try makeLoop()
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.setDaemonStateFileForTesting(stateURL)

        let mismatches = [RuntimeMismatch(component: "binary_hash", expected: "aaa", got: "bbb")]

        // Arms the first task, then -- in the same non-suspending actor
        // turn, so the freshly spawned task cannot have run any of its own
        // body yet -- rewinds the spacing clock past the 10-minute gate and
        // retriggers. Every statement inside `armRewindAndRetriggerForTesting`
        // is synchronous, so the actor cannot be preempted between arming
        // the first task and the second call: the first task is provably
        // still untouched (not started, let alone finished) when the second
        // trigger runs.
        let outcome = await loop.armRewindAndRetriggerForTesting(mismatches: mismatches)
        let firstTask = try #require(
            outcome.firstTask, "test setup: expected the first trigger to arm a task")
        #expect(
            outcome.taskAfterRetrigger != nil,
            "a second trigger while the first task is still tracked must not clear runtimeOutdatedUpdateTask")
        #expect(
            outcome.lastCheckAtAfterRetrigger == outcome.rewoundLastCheckAt,
            "a second trigger while the first task is still tracked must not re-stamp lastRuntimeUpdateCheckAt")

        let identity = try #require(ProcessIdentity.current())
        _ = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 1))

        // If the second trigger had replaced runtimeOutdatedUpdateTask with
        // a new task, drain would cancel that new task instead, and this
        // independently-held reference to the FIRST task would never be
        // touched by anything. Its cancellation here is the proof the
        // property still pointed at the same task the whole time.
        #expect(
            firstTask.isCancelled,
            "drain must cancel the ORIGINAL first task -- proves the second trigger never replaced it")
    }
}

private extension ProviderLoop {
    /// Test seam: arms the runtime-outdated trigger, then -- without
    /// yielding the actor, so the task just created cannot have started
    /// running -- rewinds `lastRuntimeUpdateCheckAt` past the 10-minute
    /// spacing gate and calls the event handler a second time. Every
    /// statement here is synchronous, so the whole sequence runs as one
    /// non-preemptible actor turn: the first task is guaranteed still live
    /// when the second call runs, deterministically, not by timing luck.
    func armRewindAndRetriggerForTesting(mismatches: [RuntimeMismatch]) -> (
        firstTask: Task<Void, Never>?,
        rewoundLastCheckAt: Double,
        taskAfterRetrigger: Task<Void, Never>?,
        lastCheckAtAfterRetrigger: Double?
    ) {
        handleRuntimeOutdatedEvent(mismatches: mismatches)
        let firstTask = runtimeOutdatedUpdateTask
        let rewound = (lastRuntimeUpdateCheckAt ?? Date().timeIntervalSince1970) - 700
        lastRuntimeUpdateCheckAt = rewound
        handleRuntimeOutdatedEvent(mismatches: mismatches)
        return (firstTask, rewound, runtimeOutdatedUpdateTask, lastRuntimeUpdateCheckAt)
    }
}
