import Foundation

/// CPU tier as Apple names it. M5-generation chips add a `super` tier above
/// `performance`; earlier chips have only `performance` and `efficiency`.
public enum CoreKind: String, Sendable, Equatable {
    case `super`
    case performance
    case efficiency
}

/// Static description of this Mac's compute layout. Read once per process.
public struct HardwareTopology: Sendable, Equatable {
    public struct CPUTier: Sendable, Equatable {
        /// `hw.perflevelN` index; 0 is the fastest tier.
        public let level: Int
        public let name: String
        public let kind: CoreKind
        public let cores: Int

        public init(level: Int, name: String, kind: CoreKind, cores: Int) {
            self.level = level
            self.name = name
            self.kind = kind
            self.cores = cores
        }
    }

    public struct CPUCluster: Sendable, Equatable {
        public let id: Int
        public let kind: CoreKind
        /// Logical CPU ids, the same indices `HardwareSample.cpuLoad` uses.
        public let cpus: [Int]

        public init(id: Int, kind: CoreKind, cpus: [Int]) {
            self.id = id
            self.kind = kind
            self.cpus = cpus
        }
    }

    public struct CPU: Sendable, Equatable {
        public let tiers: [CPUTier]
        public let clusters: [CPUCluster]

        public init(tiers: [CPUTier], clusters: [CPUCluster]) {
            self.tiers = tiers
            self.clusters = clusters
        }
    }

    public struct GPU: Sendable, Equatable {
        public let cores: Int?
        /// Enabled cores per GPU partition (mGPU); one entry when the driver
        /// does not publish partitions.
        public let groups: [Int]
        public let maxMHz: Double?

        public init(cores: Int?, groups: [Int], maxMHz: Double?) {
            self.cores = cores
            self.groups = groups
            self.maxMHz = maxMHz
        }
    }

    public let chip: String
    public let model: String
    public let cpu: CPU
    public let gpu: GPU
    public let anePresent: Bool
    public let memoryTotalBytes: UInt64

    public init(
        chip: String, model: String, cpu: CPU, gpu: GPU, anePresent: Bool, memoryTotalBytes: UInt64
    ) {
        self.chip = chip
        self.model = model
        self.cpu = cpu
        self.gpu = gpu
        self.anePresent = anePresent
        self.memoryTotalBytes = memoryTotalBytes
    }
}
