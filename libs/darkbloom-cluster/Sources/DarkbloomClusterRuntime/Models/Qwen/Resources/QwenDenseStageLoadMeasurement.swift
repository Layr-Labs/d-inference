import Foundation

/// Qualification only: record every decision of the host memory gate, and in
/// one of its two modes measure what the gate would have refused.
///
/// `record`: every decision is taken and enforced by the committed rule
/// exactly as in an installed process. The decisions, with every number the
/// rule used, and this Mac's counters once a second are kept for a report.
///
/// `measure`: the same record, and one verdict no longer stops the load or
/// request: "not enough admissible memory", at normal pressure. It answers
/// what the kernel actually does when a stage the rule would refuse is loaded
/// anyway. Everything else stops it exactly as before:
///
/// - a sample that cannot be judged (invalid, stale, critical pressure, swap in
///   use under pressure) is thrown by the policy before this type is asked;
/// - warning pressure;
/// - the growth guard: more compressed or swapped out since the first sample
///   than the committed limits;
/// - fewer truly free pages than the policy's floor;
/// - a requirement above physical memory;
/// - the allocator limit, which the callers check themselves.
///
/// Three loads of a 53 GiB stage on a 128 GiB Mac in the measuring mode are
/// why the rule was left alone: each ran into the kernel compressing anonymous
/// memory at the point the rule had predicted, and the growth guard stopped it.
///
/// Both modes are off unless a caller that was itself started with the
/// explicit qualification flag turns one on. An installed worker never does:
/// the switch is refused at startup with the other qualification switches.
public final class QwenDenseStageLoadMeasurement: @unchecked Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        /// Record only: nothing the committed rule decides is changed.
        case record
        /// Record, and do not enforce a refusal for admissible memory alone.
        case measure
    }
    /// With the value `record` or `measure`, and only beside `--qualification-switches yes`.
    public static let environmentName = "DARKBLOOM_CLUSTER_QUALIFICATION_MEMORY_GATE"
    public static let shared = QwenDenseStageLoadMeasurement()
    static let maximumDecisions = 60_000, maximumSamples = 7_200

    /// False for an instance a test owns: it records decisions it is given
    /// and never samples this Mac.
    private let samplesHost: Bool
    private let lock = NSLock()
    private var mode: Mode?
    private var started: UInt64 = 0
    private var decisions: [QwenDenseStageLoadMeasurementReport.Decision] = []
    private var samples: [QwenDenseStageLoadMeasurementReport.Sample] = []
    private var waived = 0, droppedDecisions = 0, droppedSamples = 0
    private var samplerFailure: String?
    /// The live file-backed figure at the first decision of each load or request.
    private var liveFileBackedAtFirst: [ObjectIdentifier: Int] = [:]

    init(samplesHost: Bool = true) { self.samplesHost = samplesHost }

    /// The mode the environment asks for, or nil. Any other value is refused.
    public static func requested(environment: [String: String]) throws -> Mode? {
        guard let value = environment[environmentName] else { return nil }
        guard let mode = Mode(rawValue: value) else {
            throw ProbeError("\(environmentName) takes only the values "
                + Mode.allCases.map(\.rawValue).joined(separator: " and "))
        }
        return mode
    }

    /// Turns one mode on for this process and starts the one-second sampler.
    /// `switches` must be the permission the caller was started with. The
    /// first call decides the mode; a later call for the other one is refused.
    public func enable(_ requested: Mode, permittedBy switches: QwenResidentQualificationSwitches) throws {
        guard switches.permitted else {
            throw ProbeError("The memory-gate measurement mode is a qualification switch and this process was not "
                + "started with \(QwenResidentQualificationSwitches.permittingArgument) yes")
        }
        lock.lock()
        let first = mode == nil
        if first { mode = requested; started = DispatchTime.now().uptimeNanoseconds }
        let agreed = mode == requested
        lock.unlock()
        guard agreed else { throw ProbeError("The memory-gate measurement mode is already on with another value") }
        guard first, samplesHost else { return }
        log("darkbloom-memory-gate-measurement-v3 enabled: " + (requested == .measure
            ? "a refusal for admissible memory alone is recorded and not enforced"
            : "every decision is recorded and enforced"))
        Thread.detachNewThread { [self] in
            while true {
                sample()
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return mode != nil }
    /// True only in the measuring mode: a refusal may go unenforced.
    public var waivesRefusals: Bool { lock.lock(); defer { lock.unlock() }; return mode == .measure }

    /// File cache the kernel has given up since the first decision of one
    /// load or request. The kernel's statistics can be a second old, so the
    /// figure read by sysctl is used when it shows more; a test's instance
    /// uses the decisions alone. A record only: nothing is decided from it.
    private func fileCacheGivenUp(_ decision: QwenDenseStageLoadAdmission, first: QwenDenseStageLoadAdmission?,
                                  scope: ObjectIdentifier) -> Int {
        var reclaimed = max(0, (first ?? decision).fileBackedBytes - decision.fileBackedBytes)
        if samplesHost, let pages = QwenDenseStageLoadResources.kernelCounter("vm.page_pageable_external_count") {
            let live = pages * decision.pageSizeBytes
            lock.lock()
            let atFirst = liveFileBackedAtFirst[scope] ?? live
            if liveFileBackedAtFirst[scope] == nil, liveFileBackedAtFirst.count < 256 { liveFileBackedAtFirst[scope] = live }
            lock.unlock()
            reclaimed = max(reclaimed, atFirst - live)
        }
        return reclaimed
    }

    /// Takes the mode's view of one judged decision of the watch `scope`, whose
    /// first decision was `first`: records it with what the rule said, and
    /// answers whether a refusal is one the measuring mode does not enforce.
    func judge(_ decision: QwenDenseStageLoadAdmission, first: QwenDenseStageLoadAdmission?,
               scope: ObjectIdentifier) -> Bool {
        guard isEnabled else { return false }
        let givenUp = fileCacheGivenUp(decision, first: first, scope: scope)
        let compressed = decision.compressedSinceFirstSampleBytes ?? 0
        // A load's requirement falls by what it has loaded; a request's does not move.
        let reduced = max(0, (first ?? decision).requiredBytes - decision.requiredBytes)
        lock.lock(); defer { lock.unlock() }
        let waives = mode == .measure && !decision.admitted
            && decision.pressureLevel == QwenDenseStageLoadPolicy.normalPressureLevel
            && decision.actualFreeBytes >= QwenDenseStageLoadPolicy.minimumTrulyFreeBytes
            && decision.requiredBytes <= decision.physicalMemoryBytes
            && !decision.stoppedByCompressionOrSwap
            && decision.admissibleBytes < decision.requiredBytes
        if waives { waived += 1 }
        guard decisions.count < Self.maximumDecisions else { droppedDecisions += 1; return waives }
        decisions.append(.init(seconds: seconds(), purpose: decision.purpose,
            ruleAdmitted: decision.admitted, enforced: decision.admitted || !waives,
            requiredBytes: decision.requiredBytes, admissibleBytes: decision.admissibleBytes,
            actualFreeBytes: decision.actualFreeBytes, countedReclaimableBytes: decision.countedReclaimableBytes,
            countableFileCacheBytes: decision.countableFileCacheBytes,
            fileBackedBytes: decision.fileBackedBytes, fileCacheReserveBytes: decision.fileCacheReserveBytes,
            inactiveFileBackedBytes: decision.inactiveFileBackedBytes,
            compressedSinceFirstSampleBytes: decision.compressedSinceFirstSampleBytes,
            swappedOutSinceFirstSampleBytes: decision.swappedOutSinceFirstSampleBytes,
            stoppedByCompressionOrSwap: decision.stoppedByCompressionOrSwap,
            pressureLevel: decision.pressureLevel, fileCacheGivenUpBytes: givenUp,
            compressedPerMilleOfGivenUp: givenUp > 0 ? compressed / (givenUp / 1000 + 1) : nil,
            requirementReducedBytes: reduced,
            compressedPerMilleOfRequirementReduced: reduced > 0 ? compressed / (reduced / 1000 + 1) : nil))
        return waives
    }

    private func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 }

    private func sample() {
        let observed: QwenDenseStageLoadOSObservation
        do { observed = try QwenDenseStageLoadResources.observeOS() } catch {
            lock.lock(); samplerFailure = String(describing: error); lock.unlock()
            return
        }
        let page = observed.pageSizeBytes
        lock.lock(); defer { lock.unlock() }
        guard samples.count < Self.maximumSamples else { droppedSamples += 1; return }
        samples.append(.init(seconds: seconds(), timestampUTC: observed.timestampUTC,
            freeBytes: observed.actualFreeBytes, fileBackedBytes: observed.fileBackedPages * page,
            inactiveFileBackedBytes: observed.inactiveFileBackedPages.map { $0 * page },
            inactiveAnonymousBytes: observed.inactiveAnonymousPages.map { $0 * page },
            anonymousBytes: observed.anonymousPages * page, activeBytes: observed.activePages * page,
            inactiveBytes: observed.inactivePages * page, wiredBytes: observed.wiredPages * page,
            compressorBytes: observed.compressorPages * page,
            compressionsPages: observed.compressionPages, liveCompressionsPages: observed.liveCompressionPages,
            swapoutsPages: observed.swapoutPages, swapUsedBytes: observed.swapUsedBytes,
            kernelFileCacheMinimumBytes: observed.kernelFileCacheMinimumPages.map { $0 * page },
            pressureLevel: observed.pressureLevel))
    }

    /// Nil unless a mode is on.
    public var report: QwenDenseStageLoadMeasurementReport? {
        lock.lock(); defer { lock.unlock() }
        guard let mode else { return nil }
        let refused = decisions.filter { !$0.ruleAdmitted }
        func room(_ value: QwenDenseStageLoadMeasurementReport.Decision) -> Int { value.admissibleBytes - value.requiredBytes }
        return .init(mode: mode.rawValue, policy: QwenDenseStageLoadPolicy.identifier, decisions: decisions.count,
            ruleWouldHaveRefused: refused.count, refusalsNotEnforced: waived,
            firstDecision: decisions.first, tightestDecision: decisions.min { room($0) < room($1) },
            fewestFreeDecision: decisions.min { $0.actualFreeBytes < $1.actualFreeBytes },
            lastDecision: decisions.last, firstSample: samples.first,
            fewestFreeSample: samples.min { $0.freeBytes < $1.freeBytes },
            largestCompressorSample: samples.max { $0.compressorBytes < $1.compressorBytes },
            lastSample: samples.last, decisionRows: decisions, samples: samples,
            droppedDecisionRows: droppedDecisions, droppedSamples: droppedSamples, samplerFailure: samplerFailure)
    }
}

/// The record of one process run in either mode: every decision the committed
/// rule took, and the Mac's counters once a second. A record for a
/// qualification report; nothing reads it to make a decision.
public struct QwenDenseStageLoadMeasurementReport: Encodable, Sendable {
    public struct Decision: Encodable, Sendable {
        public let seconds: Double
        public let purpose: String
        /// What the committed rule decided.
        public let ruleAdmitted: Bool
        /// False for a refusal the measuring mode recorded and did not enforce.
        public let enforced: Bool
        public let requiredBytes: Int, admissibleBytes: Int, actualFreeBytes: Int
        public let countedReclaimableBytes: Int, countableFileCacheBytes: Int
        public let fileBackedBytes: Int, fileCacheReserveBytes: Int
        public let inactiveFileBackedBytes: Int?
        public let compressedSinceFirstSampleBytes: Int?, swappedOutSinceFirstSampleBytes: Int?
        public let stoppedByCompressionOrSwap: Bool
        public let pressureLevel: Int
        /// File cache the kernel has given up since this load's or request's
        /// first decision.
        public let fileCacheGivenUpBytes: Int
        /// Compressed since the first sample per thousand of the cache given up.
        public let compressedPerMilleOfGivenUp: Int?
        /// How far the requirement has fallen since the first decision: for a
        /// load, the bytes it has loaded so far. And the compression against it.
        public let requirementReducedBytes: Int
        public let compressedPerMilleOfRequirementReduced: Int?
    }
    public struct Sample: Encodable, Sendable {
        public let seconds: Double
        public let timestampUTC: String
        public let freeBytes: Int, fileBackedBytes: Int
        public let inactiveFileBackedBytes: Int?, inactiveAnonymousBytes: Int?
        public let anonymousBytes: Int, activeBytes: Int, inactiveBytes: Int, wiredBytes: Int
        public let compressorBytes: Int
        /// Lifetime counters, in pages.
        public let compressionsPages: Int
        public let liveCompressionsPages: Int?
        public let swapoutsPages: Int
        public let swapUsedBytes: Int
        public let kernelFileCacheMinimumBytes: Int?
        public let pressureLevel: Int
    }
    public let schema = "darkbloom_memory_gate_measurement_v3"
    /// "record" or "measure".
    public let mode: String
    public let policy: String
    public let decisions: Int
    public let ruleWouldHaveRefused: Int
    public let refusalsNotEnforced: Int
    public let firstDecision: Decision?, tightestDecision: Decision?, fewestFreeDecision: Decision?, lastDecision: Decision?
    public let firstSample: Sample?, fewestFreeSample: Sample?, largestCompressorSample: Sample?, lastSample: Sample?
    public let decisionRows: [Decision]
    public let samples: [Sample]
    public let droppedDecisionRows: Int, droppedSamples: Int
    public let samplerFailure: String?
}
