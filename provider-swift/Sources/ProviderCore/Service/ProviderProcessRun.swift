import Foundation
import ProviderAppAttest

/// Process-level start facts for this serve process, established once by the
/// serve entry point (`begin`) and closed by `finish` on a clean exit or
/// before a relaunch hand-off. Diagnostics only.
public enum ProviderProcessRun {
    public struct StartContext: Sendable, Equatable {
        /// Whole seconds, as sent on the wire.
        public var processStartedAt: Int64?
        /// The run identity in the marker file.
        public var processStartMicros: UInt64?
        public var previousExit: AppAttestPreviousExit
        public var startReason: AppAttestStartReason
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var context: StartContext?
        var marker: ProviderRunMarker?
        var lifecycleCommand = false
    }

    private static let state = State()

    /// Nil until `begin` runs (tests, `darkbloom local`, CLI commands).
    public static var current: StartContext? { state.lock.withLock { state.context } }

    /// Reads the previous marker, classifies this start, then records
    /// `running`. Marker write failures never block serving.
    @discardableResult
    public static func begin(directory: URL = DaemonStateFile.path().deletingLastPathComponent(),
                             version: String = ProviderCore.version,
                             processStartMicros: UInt64? = ProcessIdentity.current()?.startTimeMicros,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             now: Date = Date()) -> StartContext {
        let marker = ProviderRunMarker(directory: directory)
        let previous = marker.read()
        let started = processStartMicros.map { Double($0) / 1_000_000 } ?? now.timeIntervalSince1970
        let reason = ProviderStartReason.classify(ProviderStartReason.Evidence(
            processStartedAt: started, now: now.timeIntervalSince1970, previousRun: previous, currentVersion: version,
            stallRestartAt: AppAttestStallRestartMarker(directory: directory).lastRestart()?.timeIntervalSince1970,
            watchdogRestartAt: WatchdogStateStore.read().lastRestartAt,
            launchedByLaunchd: ProviderStartReason.launchedByLaunchd(environment: environment),
            processStartMicros: processStartMicros))
        let context = StartContext(processStartedAt: processStartMicros.map { Int64($0 / 1_000_000) },
                                   processStartMicros: processStartMicros,
                                   previousExit: ProviderRunMarker.previousExit(previous, processStartMicros: processStartMicros),
                                   startReason: reason)
        try? marker.markRunning(processStartMicros: processStartMicros, version: version, previousExit: context.previousExit)
        state.lock.withLock {
            state.context = context
            state.marker = marker
            state.lifecycleCommand = false
        }
        return context
    }

    /// An explicit CLI stop/restart drove this process's shutdown.
    public static func noteLifecycleCommand() {
        state.lock.withLock { state.lifecycleCommand = true }
    }

    /// Marks the run clean. `cause` nil picks lifecycle_command or shutdown.
    public static func finish(cause: ProviderRunMarker.ExitCause? = nil) {
        let (marker, context, lifecycle) = state.lock.withLock { (state.marker, state.context, state.lifecycleCommand) }
        guard let marker else { return }
        try? marker.markClean(processStartMicros: context?.processStartMicros,
                              cause: cause ?? (lifecycle ? .lifecycleCommand : .shutdown))
    }

    /// A relaunch hand-off failed and this process keeps serving.
    public static func resume() {
        let (marker, context) = state.lock.withLock { (state.marker, state.context) }
        guard let marker else { return }
        try? marker.markRunning(processStartMicros: context?.processStartMicros, version: ProviderCore.version,
                                previousExit: context?.previousExit)
    }
}
