import Foundation

/// Additional scalars from the same qualified host_statistics64 read. These
/// overlapping VM categories are never summed or used as admission credit.
struct QwenResidentMemoryPages: Equatable {
    let active, wired, purgeable, fileBacked, anonymous, compressor: Int
}

enum QwenResidentMemoryPoint: String {
    case load, loadComplete, loadedRequestGuard, requestBegin, requestLive, requestRetired
    var periodic: Bool { self == .load || self == .requestLive }
}

struct QwenResidentMemorySample {
    let point: QwenResidentMemoryPoint
    let startedNanoseconds, completedNanoseconds: UInt64
    let osStartedNanoseconds, osCompletedNanoseconds: UInt64
    let physicalMemoryBytes, pageSizeBytes: Int
    let kernelFreePages, freePages, inactivePages, speculativePages: Int
    let actualFreeBytes, estimatedReclaimableBytes, pressureLevel, swapUsedBytes: Int
    let pages: QwenResidentMemoryPages
    let activeBytes, cacheBytes, peakBytes, allocatorLimitBytes: Int
    let requiredActualFreeBytes, requiredAllocatorBytes: Int
    let authorizedTensorCount: Int?, selectedTensorCount: Int?
}

struct QwenResidentMemoryTrace {
    let readyUptimeNanoseconds: UInt64
    let samples: [QwenResidentMemorySample]
}

/// One private process/request, no tensors, files, timers, clock reset or eval.
/// Periodic samples occur only at already scheduled resource checks. Mandatory
/// boundaries plus a 1-second cadence fit the unchanged <=300-second lifetime.
final class QwenResidentMemoryRecorder {
    static let maximumSamples = 320
    static let cadenceNanoseconds: UInt64 = 1_000_000_000
    let hostReservationBytes: Int
    private let rank: Int
    private let plan: String, build: String
    private let allocationBytes: Int
    private var samples: [QwenResidentMemorySample] = []
    private var ready: UInt64?
    private var bound = false, finished = false
    private var lastPeriodic: UInt64?

    init(rank: Int, plan: String, build: String, budget: QwenGenerationPhaseBudget) throws {
        guard (0...1).contains(rank), plan.utf8.count == 64, build.utf8.count == 64,
              budget.memoryLogicalBytes == Self.maximumSamples * MemoryLayout<QwenResidentMemorySample>.stride,
              budget.memoryAllocationBytes >= budget.memoryLogicalBytes else {
            throw QwenGenerationPhaseError("Invalid private phase-memory authority or allocation")
        }
        self.rank = rank; self.plan = plan; self.build = build
        hostReservationBytes = budget.requiredHostReservationBytes
        allocationBytes = budget.memoryAllocationBytes
        samples.reserveCapacity(Self.maximumSamples)
        let actual = samples.capacity.multipliedReportingOverflow(by: MemoryLayout<QwenResidentMemorySample>.stride)
        guard !actual.overflow, actual.partialValue <= allocationBytes else {
            throw QwenGenerationPhaseError("Actual memory-sample capacity exceeds its host reservation")
        }
    }

    func markReady(now: UInt64) throws {
        guard !finished, !bound, ready == nil, samples.last?.point == .loadedRequestGuard,
              let last = samples.last, now >= last.completedNanoseconds else {
            throw QwenGenerationPhaseError("Memory readiness is out of order")
        }
        ready = now
    }

    func bind(_ identity: QwenGenerationPhaseIdentity) throws {
        try identity.validate()
        guard !finished, !bound, ready != nil, identity.rank == rank,
              identity.planFingerprint == plan, identity.buildSHA256 == build,
              identity.promptCount == 8192, identity.chunkSize == 256, identity.outputCount == 128 else {
            throw QwenGenerationPhaseError("Memory observer differs from the admitted request")
        }
        bound = true
    }

    func wants(_ point: QwenResidentMemoryPoint, now: UInt64) throws -> Bool {
        if finished { return false }
        if let last = samples.last, now < last.completedNanoseconds {
            throw QwenGenerationPhaseError("Memory observation clock reversed")
        }
        guard !point.periodic || lastPeriodic == nil || now >= lastPeriodic! else {
            throw QwenGenerationPhaseError("Memory sampling cadence reversed")
        }
        return !point.periodic || lastPeriodic == nil || now - lastPeriodic! >= Self.cadenceNanoseconds
    }

    func append(_ value: QwenResidentMemorySample) throws {
        guard !finished, samples.count < Self.maximumSamples,
              value.startedNanoseconds <= value.osStartedNanoseconds,
              value.osStartedNanoseconds <= value.osCompletedNanoseconds,
              value.osCompletedNanoseconds <= value.completedNanoseconds,
              samples.last == nil || value.startedNanoseconds >= samples.last!.completedNanoseconds,
              value.completedNanoseconds - value.startedNanoseconds <= 1_000_000_000,
              value.physicalMemoryBytes > 0, value.pageSizeBytes > 0,
              value.requiredActualFreeBytes >= 6 * 1_073_741_824, value.requiredAllocatorBytes > 0,
              value.actualFreeBytes >= value.requiredActualFreeBytes,
              value.allocatorLimitBytes >= value.requiredAllocatorBytes,
              value.peakBytes >= value.activeBytes,
              [value.activeBytes, value.cacheBytes, value.peakBytes, value.pages.active,
               value.pages.wired, value.pages.purgeable, value.pages.fileBacked,
               value.pages.anonymous, value.pages.compressor].allSatisfy({ $0 >= 0 }),
              value.swapUsedBytes == 0, (0...2).contains(value.pressureLevel) else {
            throw QwenGenerationPhaseError("Invalid, overflowing or unordered admitted memory sample")
        }
        if value.point == .load || value.point == .loadComplete {
            guard let reads = value.authorizedTensorCount, let total = value.selectedTensorCount,
                  total > 0, reads >= 0, reads <= total,
                  (samples.last == nil ? reads == 0 : (samples.last?.selectedTensorCount == total
                    && reads >= (samples.last?.authorizedTensorCount ?? total))),
                  value.point != .loadComplete || reads == total else {
                throw QwenGenerationPhaseError("Memory sample changed selected-load progress")
            }
        } else if value.authorizedTensorCount != nil || value.selectedTensorCount != nil {
            throw QwenGenerationPhaseError("Request sample invented load progress")
        }
        switch value.point {
        case .load:
            guard !bound, ready == nil, samples.last == nil || samples.last?.point == .load else {
                throw QwenGenerationPhaseError("Load sample follows loaded/request state")
            }
        case .loadComplete:
            guard !bound, ready == nil, samples.last?.point == .load else {
                throw QwenGenerationPhaseError("Missing initial load observation")
            }
        case .loadedRequestGuard:
            guard !bound, ready == nil, samples.last?.point == .loadComplete else {
                throw QwenGenerationPhaseError("Loaded request guard precedes load completion")
            }
        case .requestBegin:
            guard bound, let ready, value.startedNanoseconds >= ready,
                  samples.last?.point == .loadedRequestGuard else {
                throw QwenGenerationPhaseError("Request memory sample precedes actual readiness")
            }
        case .requestLive, .requestRetired:
            guard bound, samples.last?.point == .requestBegin || samples.last?.point == .requestLive else {
                throw QwenGenerationPhaseError("Request memory state is not active")
            }
        }
        if value.point.periodic {
            if let previous = lastPeriodic, value.startedNanoseconds - previous < Self.cadenceNanoseconds {
                throw QwenGenerationPhaseError("Periodic memory sample exceeded its cadence")
            }
            lastPeriodic = value.startedNanoseconds
        }
        samples.append(value)
    }

    func retire() throws -> QwenResidentMemoryTrace {
        guard !finished, bound, let ready, samples.last?.point == .requestRetired else {
            throw QwenGenerationPhaseError("Memory trace lacks successful request retirement")
        }
        let value = QwenResidentMemoryTrace(readyUptimeNanoseconds: ready, samples: samples)
        samples = []; finished = true
        return value
    }
}
