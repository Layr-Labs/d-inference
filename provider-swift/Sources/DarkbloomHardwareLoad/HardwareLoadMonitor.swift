import Foundation

/// Demand-driven hardware sampling: the engine runs only while at least one
/// subscriber exists, plus `grace` after the last one leaves so reconnecting
/// clients do not restart (and re-baseline) the counters.
public actor HardwareLoadMonitor {
    public nonisolated let topology: HardwareTopology
    private let engine: any HardwareSamplingEngine
    private let grace: Duration
    private let freshness: TimeInterval
    private var subscribers: [UUID: AsyncStream<HardwareSample>.Continuation] = [:]
    private var latest: HardwareSample?
    private var input: AsyncStream<HardwareSample>.Continuation?
    private var idleStop: Task<Void, Never>?

    public init(
        topology: HardwareTopology, engine: any HardwareSamplingEngine,
        grace: Duration = .seconds(10), freshness: TimeInterval = 2
    ) {
        self.topology = topology
        self.engine = engine
        self.grace = grace
        self.freshness = freshness
    }

    public static func live(providerPID: @escaping @Sendable () -> Int32?) -> HardwareLoadMonitor {
        HardwareLoadMonitor(
            topology: TopologyProbe.read(), engine: ThreadSamplingEngine(providerPID: providerPID))
    }

    public var isSampling: Bool { input != nil }
    public var subscriberCount: Int { subscribers.count }

    /// Live samples until the consumer stops iterating. A fresh latest sample
    /// is delivered first so a reconnect never waits a full window.
    public func samples() -> AsyncStream<HardwareSample> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: HardwareSample.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        if let latest, isFresh(latest) { continuation.yield(latest) }
        startIfNeeded()
        return stream
    }

    /// The latest sample, waiting up to `timeout` for one when none is fresh.
    /// Counts as demand, so sampling continues for `grace` afterwards.
    public func currentSample(waitingUpTo timeout: Duration) async -> HardwareSample? {
        if let latest, isFresh(latest) { return latest }
        let stream = samples()
        return await withTaskGroup(of: HardwareSample?.self) { group in
            group.addTask {
                for await sample in stream { return sample }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func isFresh(_ sample: HardwareSample) -> Bool {
        Date().timeIntervalSince(sample.sampledAt) < freshness
    }

    private func startIfNeeded() {
        idleStop?.cancel()
        idleStop = nil
        guard input == nil else { return }
        // A stream (not a Task per sample) keeps samples in emission order.
        let (samples, continuation) = AsyncStream.makeStream(
            of: HardwareSample.self, bufferingPolicy: .bufferingNewest(4))
        input = continuation
        engine.start { continuation.yield($0) }
        Task { [weak self] in
            for await sample in samples { await self?.publish(sample) }
        }
    }

    private func publish(_ sample: HardwareSample) {
        latest = sample
        for subscriber in subscribers.values { subscriber.yield(sample) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        guard subscribers.isEmpty, input != nil else { return }
        idleStop?.cancel()
        let grace = grace
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard subscribers.isEmpty, let input else { return }
        engine.stop()
        input.finish()
        self.input = nil
        idleStop = nil
    }
}
