// Copyright © 2026 Eigen Labs.
//
// In-situ dump of the engine's decode-step profile (`CBv2StepProfiler`).
//
// `CBV2_STEP_PROFILE=1` arms the engine's phase timers, but until now only
// `BenchCBv2 --mode profile` ever printed `summaryTable()`, at B=1, so a
// serving provider had no way to read its own step decomposition at B>1.
// `darkbloom status` is a separate process (it reads the daemon state file)
// and cannot reach this process-static profiler, so the dump is signal
// driven: SIGUSR1 renders the table (bucketed by token-producing rows —
// `v2.step.wall[b4]` is the B=4 decode step) to stderr and the unified log.
//
// Armed only when the profiler is enabled; otherwise SIGUSR1 keeps its
// default disposition and the provider pays nothing.

import Foundation
import MLXLMCommon

public enum EngineStepProfileDump {

    /// The engine's opt-in switch (read once by `CBv2StepProfiler.enabled`).
    public static let environmentKey = "CBV2_STEP_PROFILE"

    nonisolated(unsafe) private static var source: DispatchSourceSignal?
    private static let lock = NSLock()

    /// Arm the SIGUSR1 dump when `CBV2_STEP_PROFILE` enabled the profiler.
    /// Idempotent. Returns whether a handler is armed after the call.
    @discardableResult
    public static func armIfEnabled(
        sink: @escaping @Sendable (String) -> Void = { text in
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
    ) -> Bool {
        guard CBv2StepProfiler.enabled else { return false }
        lock.lock()
        defer { lock.unlock() }
        if source != nil { return true }
        signal(SIGUSR1, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(
            signal: SIGUSR1, queue: DispatchQueue.global(qos: .utility))
        signalSource.setEventHandler { sink(render()) }
        signalSource.resume()
        source = signalSource
        return true
    }

    /// The report text: a one-line status when the profiler is off, else the
    /// markdown phase table (per phase: n, total, mean, p50, p95, max ms).
    public static func render(
        enabled: Bool = CBv2StepProfiler.enabled,
        table: () -> String = { CBv2StepProfiler.summaryTable() }
    ) -> String {
        guard enabled else {
            return "engine step profile: disabled (start with CBV2_STEP_PROFILE=1)"
        }
        return "engine step profile (CBV2_STEP_PROFILE=1; rows bucketed as [bN])\n" + table()
    }
}
