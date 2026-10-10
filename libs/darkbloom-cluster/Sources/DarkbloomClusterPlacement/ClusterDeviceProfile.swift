import Foundation

/// What one Mac detects about itself when asked: its chip and cores as the
/// system names them, its OS build, its memory, what its GPU says it can keep
/// resident, and what the host memory gate would admit right now.
///
/// Nothing here is looked up by machine. It carries no host name, serial
/// number, address, user name or path, so it can be shown, logged and sent to
/// a peer. It is an observation, never an authority: a load is admitted by
/// the load gate on the Mac that loads, whatever a profile said earlier.
public struct ClusterDeviceProfile: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_device_profile_v1"
    public static let maximumEncodedBytes = 16_384

    public let schema: String
    /// `machdep.cpu.brand_string`. A cache key and a label, never a planning input.
    public let chip: String
    public let performanceCores: Int
    public let efficiencyCores: Int
    /// The accelerator's core count when the system publishes it.
    public let gpuCores: Int?
    public let osVersion: String
    public let osBuild: String
    public let physicalMemoryBytes: Int
    /// What the GPU says an application may keep resident on this Mac.
    public let gpuRecommendedWorkingSetBytes: Int
    /// The largest single buffer the GPU accepts.
    public let gpuMaximumBufferBytes: Int
    /// The allocator's limit in a fresh worker process; the load gate's second comparison.
    public let allocatorLimitBytes: Int
    public let memory: ClusterDeviceMemory
    public let power: ClusterDevicePower

    public init(chip: String, performanceCores: Int, efficiencyCores: Int, gpuCores: Int?,
                osVersion: String, osBuild: String, physicalMemoryBytes: Int,
                gpuRecommendedWorkingSetBytes: Int, gpuMaximumBufferBytes: Int, allocatorLimitBytes: Int,
                memory: ClusterDeviceMemory, power: ClusterDevicePower) throws {
        schema = Self.schemaName
        self.chip = chip; self.performanceCores = performanceCores; self.efficiencyCores = efficiencyCores
        self.gpuCores = gpuCores; self.osVersion = osVersion; self.osBuild = osBuild
        self.physicalMemoryBytes = physicalMemoryBytes
        self.gpuRecommendedWorkingSetBytes = gpuRecommendedWorkingSetBytes
        self.gpuMaximumBufferBytes = gpuMaximumBufferBytes; self.allocatorLimitBytes = allocatorLimitBytes
        self.memory = memory; self.power = power
        try validate()
    }

    /// A profile from another Mac is untrusted input: bounded, plain text
    /// labels and counters that cannot contradict each other.
    public func validate() throws {
        func label(_ value: String, _ limit: Int = 96) -> Bool {
            !value.isEmpty && value.utf8.count <= limit
                && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
        }
        guard schema == Self.schemaName, label(chip), label(osVersion, 32), label(osBuild, 32),
              (0...1024).contains(performanceCores), (0...1024).contains(efficiencyCores),
              performanceCores + efficiencyCores > 0, gpuCores.map({ (1...4096).contains($0) }) ?? true,
              physicalMemoryBytes > 0, physicalMemoryBytes == memory.physicalMemoryBytes,
              gpuRecommendedWorkingSetBytes >= 0, gpuMaximumBufferBytes >= 0, allocatorLimitBytes >= 0 else {
            throw ClusterPlacementError("Device profile is malformed")
        }
        try memory.validate()
        try power.validate()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ClusterDeviceProfile {
        guard (2...maximumEncodedBytes).contains(data.count) else {
            throw ClusterPlacementError("Device profile is empty or larger than \(maximumEncodedBytes) bytes")
        }
        let value = try JSONDecoder().decode(ClusterDeviceProfile.self, from: data)
        try value.validate()
        return value
    }

    /// The answer for one range: what the load and request gates would need
    /// to admit (`needBytes`), and what the allocator would need to hold.
    public func fit(needBytes: Int, weightsBytes: Int, largestTensorBytes: Int) -> ClusterPlacementFit {
        // The allocator's limit and the GPU's buffer limit are hardware bounds:
        // no amount of freed memory moves them.
        if largestTensorBytes > gpuMaximumBufferBytes {
            return .never(shortBytes: largestTensorBytes - gpuMaximumBufferBytes)
        }
        let allocator = weightsBytes + largestTensorBytes + memory.allocatorHeadroomBytes
        if allocator > allocatorLimitBytes { return .never(shortBytes: allocator - allocatorLimitBytes) }
        return memory.fit(needBytes)
    }
}

/// The host memory gate's own decision on one sample, reduced to the numbers
/// a planner can carry. Every field is copied from the gate's decision record
/// or is one of the gate's constants as the gate reported it; nothing here is
/// computed by a second formula. `admits` is the gate's comparison.
public struct ClusterDeviceMemory: Codable, Equatable, Sendable {
    /// The gate rule that produced these numbers.
    public let gatePolicy: String
    public let sampledUTC: String
    /// False when the gate would not judge the sample at all (critical
    /// pressure, swap in use under pressure, counters that contradict each
    /// other). Nothing is admitted on such a sample.
    public let judged: Bool
    public let unjudgedReason: String?
    public let physicalMemoryBytes: Int
    public let actualFreeBytes: Int
    /// File cache the gate counts for a decision taken now.
    public let countedFileCacheBytes: Int
    /// Free plus counted: what a decision taken now is compared with.
    public let admissibleNowBytes: Int
    public let fileBackedBytes: Int
    /// The kernel's own file-cache minimum on this sample. It gives cache up
    /// freely down to this and then turns to compressing applications, so
    /// cache below it is not memory a model can be given.
    public let fileCacheReserveBytes: Int
    /// File cache above that minimum: what the kernel would give up before
    /// it touches an application. The gate counts part of it.
    public let fileCacheAboveReserveBytes: Int
    public let anonymousBytes: Int
    public let wiredBytes: Int
    public let compressorBytes: Int
    /// Active plus inactive plus free, as the gate sums them.
    public let pageableBytes: Int
    public let pressureLevel: Int
    public let swapUsedBytes: Int
    /// The gate's constants, as reported by the gate on that Mac.
    public let minimumAdmissibleBytes: Int
    public let minimumTrulyFreeBytes: Int
    public let loadingHeadroomBytes: Int
    public let allocatorHeadroomBytes: Int
    public let loadScratchBytes: Int
    /// The allocator rounds each tensor up to at most this much more.
    public let pageSizeBytes: Int

    public init(gatePolicy: String, sampledUTC: String, judged: Bool, unjudgedReason: String?,
                physicalMemoryBytes: Int, actualFreeBytes: Int, countedFileCacheBytes: Int,
                admissibleNowBytes: Int, fileBackedBytes: Int, fileCacheReserveBytes: Int,
                fileCacheAboveReserveBytes: Int, anonymousBytes: Int, wiredBytes: Int,
                compressorBytes: Int, pageableBytes: Int, pressureLevel: Int, swapUsedBytes: Int,
                minimumAdmissibleBytes: Int, minimumTrulyFreeBytes: Int, loadingHeadroomBytes: Int,
                allocatorHeadroomBytes: Int, loadScratchBytes: Int, pageSizeBytes: Int) {
        self.gatePolicy = gatePolicy; self.sampledUTC = sampledUTC; self.judged = judged
        self.unjudgedReason = unjudgedReason; self.physicalMemoryBytes = physicalMemoryBytes
        self.actualFreeBytes = actualFreeBytes; self.countedFileCacheBytes = countedFileCacheBytes
        self.admissibleNowBytes = admissibleNowBytes; self.fileBackedBytes = fileBackedBytes
        self.fileCacheReserveBytes = fileCacheReserveBytes; self.fileCacheAboveReserveBytes = fileCacheAboveReserveBytes
        self.anonymousBytes = anonymousBytes; self.wiredBytes = wiredBytes
        self.compressorBytes = compressorBytes; self.pageableBytes = pageableBytes
        self.pressureLevel = pressureLevel; self.swapUsedBytes = swapUsedBytes
        self.minimumAdmissibleBytes = minimumAdmissibleBytes; self.minimumTrulyFreeBytes = minimumTrulyFreeBytes
        self.loadingHeadroomBytes = loadingHeadroomBytes; self.allocatorHeadroomBytes = allocatorHeadroomBytes
        self.loadScratchBytes = loadScratchBytes; self.pageSizeBytes = pageSizeBytes
    }

    func validate() throws {
        let counters = [physicalMemoryBytes, actualFreeBytes, countedFileCacheBytes, admissibleNowBytes,
            fileBackedBytes, fileCacheReserveBytes, fileCacheAboveReserveBytes, anonymousBytes, wiredBytes,
            compressorBytes, pageableBytes, swapUsedBytes,
            minimumAdmissibleBytes, minimumTrulyFreeBytes, loadingHeadroomBytes, allocatorHeadroomBytes,
            loadScratchBytes, pressureLevel]
        guard (1...1_048_576).contains(pageSizeBytes), !gatePolicy.isEmpty, gatePolicy.utf8.count <= 96, sampledUTC.utf8.count <= 64,
              (unjudgedReason?.utf8.count ?? 0) <= 512, counters.allSatisfy({ $0 >= 0 }),
              physicalMemoryBytes > 0, actualFreeBytes <= physicalMemoryBytes,
              pageableBytes <= physicalMemoryBytes, fileBackedBytes <= physicalMemoryBytes,
              anonymousBytes <= physicalMemoryBytes, wiredBytes <= physicalMemoryBytes,
              compressorBytes <= physicalMemoryBytes,
              admissibleNowBytes == actualFreeBytes + countedFileCacheBytes,
              fileCacheAboveReserveBytes <= fileBackedBytes, countedFileCacheBytes <= fileCacheAboveReserveBytes,
              judged == (unjudgedReason == nil) else {
            throw ClusterPlacementError("Device memory record contradicts itself")
        }
    }

    /// The gate's decision for a requirement, by the gate's own comparisons:
    /// a judged sample, the truly-free floor, the requirement after the floor
    /// against physical memory and against admissible memory.
    public func admits(_ requiredBytes: Int) -> Bool {
        guard judged, requiredBytes >= 0 else { return false }
        let required = max(minimumAdmissibleBytes, requiredBytes)
        return actualFreeBytes >= minimumTrulyFreeBytes && required <= physicalMemoryBytes
            && admissibleNowBytes >= required
    }

    /// Free pages plus the file cache above the kernel's minimum: what this
    /// Mac can give a model without an application losing memory. The gate
    /// admits on part of it; the rest is the gate's margin, not memory in use.
    public var kernelWouldGiveBytes: Int { actualFreeBytes + fileCacheAboveReserveBytes }

    /// What this Mac could give with every application closed: everything
    /// pageable except the file cache the kernel keeps for itself. Closing an
    /// application turns its memory into free pages; it does not shrink the
    /// kernel's cache minimum.
    public var withApplicationsClosedBytes: Int { max(0, pageableBytes - min(fileBackedBytes, fileCacheReserveBytes)) }

    /// What a restart could give: everything that is not wired. Nothing the
    /// owner can do in a session reaches this.
    public var afterRestartBytes: Int { min(physicalMemoryBytes, pageableBytes + compressorBytes) }

    /// Which answer a requirement gets on this Mac.
    public func fit(_ requiredBytes: Int) -> ClusterPlacementFit {
        if admits(requiredBytes) { return .now }
        let required = max(minimumAdmissibleBytes, requiredBytes)
        if required > physicalMemoryBytes { return .never(shortBytes: required - physicalMemoryBytes) }
        // A sample the gate would not judge says nothing about what is free.
        guard judged else { return .afterApplicationsRelease(bytes: required) }
        if required <= kernelWouldGiveBytes { return .gateCountsLess(bytes: max(0, required - admissibleNowBytes)) }
        if required <= withApplicationsClosedBytes { return .afterApplicationsRelease(bytes: required - kernelWouldGiveBytes) }
        if required <= afterRestartBytes { return .afterRestart(bytes: required - withApplicationsClosedBytes) }
        return .never(shortBytes: required - afterRestartBytes)
    }
}

/// The three things the request gate refuses on besides memory.
public struct ClusterDevicePower: Codable, Equatable, Sendable {
    public let onExternalPower: Bool
    public let lowPowerMode: Bool
    /// `nominal`, `fair`, `serious` or `critical`.
    public let thermalState: String

    public init(onExternalPower: Bool, lowPowerMode: Bool, thermalState: String) {
        self.onExternalPower = onExternalPower; self.lowPowerMode = lowPowerMode; self.thermalState = thermalState
    }

    func validate() throws {
        guard ["nominal", "fair", "serious", "critical"].contains(thermalState) else {
            throw ClusterPlacementError("Device power record names an unknown thermal state")
        }
    }

    /// Mirrors `QwenResidentResourceEnvironment.require`: external power,
    /// normal power mode, thermal state nominal or fair.
    public var admitsExecution: Bool {
        onExternalPower && !lowPowerMode && (thermalState == "nominal" || thermalState == "fair")
    }
}

/// One device's answer to one requirement, best first. The remedies differ,
/// so the answers are kept apart: free pages and countable cache are there
/// now; cache above the kernel's minimum is there but only partly counted by
/// the gate; applications can be closed; the kernel's own cache minimum goes
/// only with a restart.
public enum ClusterPlacementFit: Codable, Equatable, Sendable {
    /// The gate would admit it on the sample in the profile.
    case now
    /// The kernel would give this Mac's file cache above its minimum to the
    /// load without touching an application, and that would be enough; the
    /// gate counts less of that cache than there is, so it refuses, by this
    /// many bytes. The gate's rule refuses here, not the Mac's memory.
    case gateCountsLess(bytes: Int)
    /// Applications would have to release this much first.
    case afterApplicationsRelease(bytes: Int)
    /// Even with every application closed it is this much short, because the
    /// kernel keeps its minimum of file cache. Only a restart empties that.
    case afterRestart(bytes: Int)
    /// Not on this Mac: short by this much of what is not wired, or beyond
    /// the allocator's or the GPU's own limit.
    case never(shortBytes: Int)

    /// 0 best. A candidate's tier is its worst device's.
    public var tier: Int {
        switch self {
        case .now: return 0
        case .gateCountsLess: return 1
        case .afterApplicationsRelease: return 2
        case .afterRestart: return 3
        case .never: return 4
        }
    }
    public var possible: Bool { tier < 4 }
}

public struct ClusterPlacementError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
