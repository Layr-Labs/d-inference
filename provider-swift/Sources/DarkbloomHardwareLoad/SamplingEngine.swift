import Foundation

/// Produces samples while started. `HardwareLoadMonitor` owns the start/stop policy.
public protocol HardwareSamplingEngine: Sendable {
    /// Begins emitting samples; a no-op while already running.
    func start(emit: @escaping @Sendable (HardwareSample) -> Void)
    func stop()
}

/// Samples on a dedicated thread: ANE power at 10 Hz, a full sample every
/// tenth poll (1 Hz). IOReport's PMP read blocks for milliseconds, so it must
/// not run on an actor or the cooperative pool.
public final class ThreadSamplingEngine: HardwareSamplingEngine, @unchecked Sendable {
    private static let pollInterval: TimeInterval = 0.1
    private static let pollsPerSample = 10

    private let lock = NSLock()
    private var current: StopFlag?
    private let providerPID: @Sendable () -> Int32?

    /// `providerPID` runs on the sampling thread once per sample.
    public init(providerPID: @escaping @Sendable () -> Int32?) {
        self.providerPID = providerPID
    }

    public func start(emit: @escaping @Sendable (HardwareSample) -> Void) {
        lock.withLock {
            guard current == nil else { return }
            let flag = StopFlag()
            current = flag
            let providerPID = providerPID
            let thread = Thread { Self.run(flag: flag, providerPID: providerPID, emit: emit) }
            thread.name = "darkbloom.hardware-load"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    public func stop() {
        lock.withLock {
            current?.stop()
            current = nil
        }
    }

    private static func run(
        flag: StopFlag, providerPID: @escaping @Sendable () -> Int32?,
        emit: @Sendable (HardwareSample) -> Void
    ) {
        let sampler = HardwareSampler(providerPID: providerPID)
        var deadline = Date()
        while !flag.isStopped {
            for _ in 0..<pollsPerSample {
                deadline += pollInterval
                // After sleep/wake the deadline is far behind; restart the cadence.
                if deadline < Date(timeIntervalSinceNow: -1) { deadline = Date() }
                Thread.sleep(until: deadline)
                if flag.isStopped { return }
                sampler.pollANE()
            }
            emit(sampler.sample())
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}
