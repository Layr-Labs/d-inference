import Foundation
import Dispatch

/// Coarse memory-pressure level from the kernel (DISPATCH_SOURCE_MEMORYPRESSURE).
public enum MemoryPressureLevel: String, Sendable, Equatable {
    case normal
    case warning
    case critical
}

/// What the provider should do at a given pressure level.
public struct MemoryPressureResponse: Equatable, Sendable {
    /// Drop MLX's reusable buffer pool back to the OS immediately.
    public var clearCache: Bool
    /// Persist an OOM marker so that if jetsam SIGKILLs us next, the following
    /// launch can attribute the death to memory pressure.
    public var writeMarker: Bool
    /// Telemetry severity to emit (nil = don't emit).
    public var severity: TelemetrySeverity?
}

/// Pure policy: pressure level -> action. Tested in isolation.
public enum MemoryPressurePolicy {
    public static func response(for level: MemoryPressureLevel) -> MemoryPressureResponse {
        switch level {
        case .normal:
            return MemoryPressureResponse(clearCache: false, writeMarker: false, severity: nil)
        case .warning:
            // Reclaim the cache early; the live admission gate (GlobalKVCacheBudget /
            // tokenBudgetMax, now OS-available-aware) naturally tightens as free RAM
            // falls, so no forced shedding is needed yet — just return memory. No
            // telemetry: warning pressure is routine on healthy Macs and would
            // only add noise to the `oom` signal.
            return MemoryPressureResponse(clearCache: true, writeMarker: false, severity: nil)
        case .critical:
            // Last chance before a possible jetsam kill: reclaim everything AND
            // drop a marker so the death isn't invisible.
            return MemoryPressureResponse(clearCache: true, writeMarker: true, severity: .error)
        }
    }
}

/// Watches kernel memory pressure and reacts. MLX-free by design: the caller
/// injects the `clearCache` / `writeMarker` / `emit` actions so this stays
/// testable and the file has no MLX dependency. `handle(_:)` is the testable
/// core; `start()` wires it to a real DispatchSource.
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let clearCache: @Sendable () -> Void
    private let writeMarker: @Sendable (MemoryPressureLevel) -> Void
    private let emit: @Sendable (MemoryPressureLevel, TelemetrySeverity) -> Void
    private let queue: DispatchQueue
    private var source: DispatchSourceMemoryPressure?

    public init(
        queue: DispatchQueue = DispatchQueue(label: "dev.darkbloom.memory-pressure"),
        clearCache: @escaping @Sendable () -> Void,
        writeMarker: @escaping @Sendable (MemoryPressureLevel) -> Void,
        emit: @escaping @Sendable (MemoryPressureLevel, TelemetrySeverity) -> Void
    ) {
        self.queue = queue
        self.clearCache = clearCache
        self.writeMarker = writeMarker
        self.emit = emit
    }

    public func start() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, let data = self.source?.data else { return }
            self.handle(Self.level(from: data))
        }
        self.source = src
        src.activate()
    }

    public func cancel() {
        source?.cancel()
        source = nil
    }

    /// Testable core: apply the policy for a level and invoke the injected
    /// actions. Safe to call directly from tests.
    public func handle(_ level: MemoryPressureLevel) {
        let response = MemoryPressurePolicy.response(for: level)
        if response.clearCache { clearCache() }
        if response.writeMarker { writeMarker(level) }
        if let severity = response.severity { emit(level, severity) }
    }

    /// Map a DispatchSource.MemoryPressureEvent bitmask to our coarse level.
    /// Critical dominates warning when both bits are set.
    static func level(from data: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        if data.contains(.critical) { return .critical }
        if data.contains(.warning) { return .warning }
        return .normal
    }
}
