import Foundation

public enum ThermalState: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}

/// One whole-machine load sample. Every optional is nil when its source is
/// unavailable or has not produced a trustworthy value yet; nil never means 0.
public struct HardwareSample: Sendable, Equatable {
    public struct GPU: Sendable, Equatable {
        public var utilization: Double?
        public var frequencyMHz: Double?
        public var powerW: Double?
        /// The provider's fraction (0…1) of all GPU time in the window.
        public var providerShare: Double?
        public var memoryInUseBytes: UInt64?

        public init(
            utilization: Double? = nil, frequencyMHz: Double? = nil, powerW: Double? = nil,
            providerShare: Double? = nil, memoryInUseBytes: UInt64? = nil
        ) {
            self.utilization = utilization
            self.frequencyMHz = frequencyMHz
            self.powerW = powerW
            self.providerShare = providerShare
            self.memoryInUseBytes = memoryInUseBytes
        }
    }

    public struct ANE: Sendable, Equatable {
        /// Fraction of the window the ANE was powered (10 Hz polls).
        public var active: Double?
        public var bandwidthGBps: Double?
        public var powerW: Double?

        public init(active: Double? = nil, bandwidthGBps: Double? = nil, powerW: Double? = nil) {
            self.active = active
            self.bandwidthGBps = bandwidthGBps
            self.powerW = powerW
        }
    }

    public struct Memory: Sendable, Equatable {
        public var usedBytes: UInt64?
        public var wiredBytes: UInt64?
        public var pressure: MemoryPressure?
        public var bandwidthGBps: Double?

        public init(
            usedBytes: UInt64? = nil, wiredBytes: UInt64? = nil, pressure: MemoryPressure? = nil,
            bandwidthGBps: Double? = nil
        ) {
            self.usedBytes = usedBytes
            self.wiredBytes = wiredBytes
            self.pressure = pressure
            self.bandwidthGBps = bandwidthGBps
        }
    }

    public var sampledAt: Date
    public var interval: Duration
    /// Busy fraction per logical CPU id; empty when tick counters are unreadable.
    public var cpuLoad: [Double]
    public var gpu: GPU
    public var ane: ANE
    public var memory: Memory
    public var thermal: ThermalState
    public var providerRunning: Bool
    public var capabilities: [String: CapabilityStatus]

    public init(
        sampledAt: Date, interval: Duration, cpuLoad: [Double] = [], gpu: GPU = GPU(),
        ane: ANE = ANE(), memory: Memory = Memory(), thermal: ThermalState = .nominal,
        providerRunning: Bool = false, capabilities: [String: CapabilityStatus] = [:]
    ) {
        self.sampledAt = sampledAt
        self.interval = interval
        self.cpuLoad = cpuLoad
        self.gpu = gpu
        self.ane = ane
        self.memory = memory
        self.thermal = thermal
        self.providerRunning = providerRunning
        self.capabilities = capabilities
    }
}
