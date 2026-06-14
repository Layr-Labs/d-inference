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
    public var clearCache: Bool             // reclaim MLX's buffer pool to the OS
    public var writeMarker: Bool            // drop an OOM marker for the next launch
    public var severity: TelemetrySeverity? // nil = don't emit telemetry
}

/// Pure policy: pressure level -> action. Tested in isolation.
public enum MemoryPressurePolicy {
    public static func response(for level: MemoryPressureLevel) -> MemoryPressureResponse {
        switch level {
        case .normal:
            return MemoryPressureResponse(clearCache: false, writeMarker: false, severity: nil)
        case .warning:
            // Reclaim cache; the live admission gate handles shedding. No telemetry
            // — warning pressure is routine and would only add noise.
            return MemoryPressureResponse(clearCache: true, writeMarker: false, severity: nil)
        case .critical:
            // Last chance before a possible jetsam kill: reclaim + mark for next launch.
            return MemoryPressureResponse(clearCache: true, writeMarker: true, severity: .error)
        }
    }
}

/// Watches kernel memory pressure and reacts. MLX-free: the caller injects the
/// actions so it stays testable. `handle(_:)` is the core; `start()` wires the
/// real DispatchSource.
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
