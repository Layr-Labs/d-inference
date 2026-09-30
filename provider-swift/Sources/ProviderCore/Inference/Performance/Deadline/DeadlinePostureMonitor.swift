import Foundation

/// One sampler exists only while a loaded bridge owns reviewed deadline
/// evidence. Admission reads the cached state; it never starts or awaits an OS
/// process. Qualification and runtime both observe thermal state every 500ms;
/// this revision admits reviewed evidence only on AC power in Automatic mode.
final class DeadlinePostureMonitor: @unchecked Sendable {
    static let shared = DeadlinePostureMonitor()
    let state = DeadlinePostureState()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "darkbloom.deadline-posture", qos: .utility)
    private let powerQueue = DispatchQueue(label: "darkbloom.deadline-power-policy", qos: .utility)
    private let readModes: @Sendable () -> [String: Int]?
    private let activeSource: @Sendable () -> String?
    private let readThermal: @Sendable () -> (nominal: Bool, lowPower: Bool)
    private var owners: Set<UUID> = []
    private var generation: UInt64 = 0
    private var timer: DispatchSourceTimer?
    // The remaining fields are confined to queue.
    private var sampledGeneration: UInt64 = 0
    private var modes: [String: Int]?
    private var powerReadAt: ContinuousClock.Instant?
    private var nextPowerRead = ContinuousClock.now
    private var readingPower = false

    init(readModes: @escaping @Sendable () -> [String: Int]? = DeadlinePowerPolicyReader.readModes,
        activeSource: @escaping @Sendable () -> String? = DeadlinePowerPolicyReader.activeSource,
        readThermal: @escaping @Sendable () -> (nominal: Bool, lowPower: Bool) = {
            (ProcessInfo.processInfo.thermalState == .nominal, ProcessInfo.processInfo.isLowPowerModeEnabled)
        }) {
        self.readModes = readModes
        self.activeSource = activeSource
        self.readThermal = readThermal
    }

    func acquire() -> DeadlinePostureLease {
        let owner = UUID()
        lock.withLock {
            owners.insert(owner)
            guard timer == nil else { return }
            generation &+= 1
            let current = generation
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.sample(generation: current) }
            self.timer = timer
            timer.resume()
        }
        return DeadlinePostureLease { [self] in release(owner) }
    }

    private func release(_ owner: UUID) {
        let stopped = lock.withLock { () -> Bool in
            guard owners.remove(owner) != nil, owners.isEmpty else { return false }
            generation &+= 1
            timer?.cancel()
            timer = nil
            return true
        }
        if stopped {
            state.observe(nominal: false, lowPower: false, automatic: false,
                source: nil, powerReadAt: nil, at: .now)
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { self.generation == generation && !owners.isEmpty }
    }

    private func sample(generation: UInt64) {
        guard isCurrent(generation) else { return }
        let now = ContinuousClock.now
        if sampledGeneration != generation {
            sampledGeneration = generation
            modes = nil
            powerReadAt = nil
            nextPowerRead = now
            readingPower = false
        }
        if !readingPower && now >= nextPowerRead {
            readingPower = true
            nextPowerRead = now.advanced(by: .seconds(2))
            powerQueue.async { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                let modes = self.readModes()
                self.queue.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.modes = modes
                    self.powerReadAt = modes == nil ? nil : .now
                    self.readingPower = false
                    self.sample(generation: generation)
                }
            }
        }
        let source = activeSource()
        let thermal = readThermal()
        guard isCurrent(generation) else { return }
        state.observe(nominal: thermal.nominal, lowPower: thermal.lowPower,
            automatic: source.flatMap { modes?[$0] } == 0,
            source: source, powerReadAt: powerReadAt, at: now)
    }
}

final class DeadlinePostureLease: @unchecked Sendable {
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?
    init(release: @escaping @Sendable () -> Void) { self.release = release }
    func finish() {
        let callback = lock.withLock { defer { release = nil }; return release }
        callback?()
    }
    deinit { finish() }
}
