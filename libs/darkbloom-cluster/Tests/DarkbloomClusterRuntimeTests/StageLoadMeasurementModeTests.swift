import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// The host memory gate's qualification-only record and measure modes. Observations are
// constructed, and every test owns its own measurement instance: the process's
// shared one is never turned on here, so no other suite's gate changes.

@Suite("Stage load measurement mode (constructed observations)")
struct StageLoadMeasurementModeTests {
    private typealias Mac = ConstructedMac
    private static let gib = ConstructedMac.gib, mib = ConstructedMac.mib, page = ConstructedMac.page

    private static func measuring(_ mode: QwenDenseStageLoadMeasurement.Mode = .measure) throws
        -> (QwenDenseStageLoadMeasurement, QwenDenseStageLoadWatch) {
        let measurement = QwenDenseStageLoadMeasurement(samplesHost: false)
        try measurement.enable(mode, permittedBy: .permittedByExplicitFlag)
        return (measurement, QwenDenseStageLoadWatch("Test load", list: nil, measurement: measurement))
    }

    private static func thrown(_ body: () throws -> Bool) -> String? {
        do { _ = try body(); return nil } catch { return String(describing: error) }
    }

    @Test func theModeIsOffUnlessAPermittedCallerTurnsItOn() throws {
        let measurement = QwenDenseStageLoadMeasurement(samplesHost: false)
        #expect(!measurement.isEnabled && measurement.report == nil)
        for mode in QwenDenseStageLoadMeasurement.Mode.allCases {
            #expect(throws: (any Error).self) { try measurement.enable(mode, permittedBy: .refused) }
        }
        #expect(!measurement.isEnabled && !measurement.waivesRefusals)
        // Off: the committed rule refuses exactly as it always did, and nothing is recorded.
        let watch = QwenDenseStageLoadWatch("Test load", list: nil, measurement: measurement)
        let refused = Self.thrown { try watch.admits(Mac.observation(), bytes: 100 * Self.gib, now: Mac.now) }
        #expect(refused?.hasPrefix("Test load needs 100.00 GiB of admissible memory and has 30.25 GiB") == true)
        #expect(measurement.report == nil && watch.summary.refusals == 1)
        // The process's own instance is off in a test run.
        #expect(!QwenDenseStageLoadMeasurement.shared.isEnabled)
    }

    @Test func theSwitchIsRefusedAtStartupWithoutTheQualificationFlag() throws {
        let name = QwenDenseStageLoadMeasurement.environmentName
        #expect(name == QwenResidentQualificationSwitches.memoryGateEnvironmentName)
        #expect(throws: (any Error).self) { try QwenResidentQualificationSwitches.refused.admit(environment: [name: "measure"]) }
        try QwenResidentQualificationSwitches.permittedByExplicitFlag.admit(environment: [name: "measure"])
        try QwenResidentQualificationSwitches.refused.admit(environment: [:])
        try QwenResidentQualificationSwitches.permittedByExplicitFlag.admit(environment: [name: "record"])
        #expect(throws: (any Error).self) { try QwenResidentQualificationSwitches.refused.admit(environment: [name: "record"]) }
        #expect(try QwenDenseStageLoadMeasurement.requested(environment: [name: "measure"]) == .measure)
        #expect(try QwenDenseStageLoadMeasurement.requested(environment: [name: "record"]) == .record)
        #expect(try QwenDenseStageLoadMeasurement.requested(environment: [:]) == nil)
        for other in ["", "1", "on", "Measure", "enforce", "recording"] {
            #expect(throws: (any Error).self) { _ = try QwenDenseStageLoadMeasurement.requested(environment: [name: other]) }
        }
    }

    @Test func aRefusalForAdmissibleMemoryAloneIsRecordedAndNotEnforced() throws {
        let (measurement, watch) = try Self.measuring()
        // 0.25 GiB free and 30 GiB counted against 100 GiB: the committed rule refuses.
        #expect(try watch.admits(Mac.observation(), bytes: 100 * Self.gib, now: Mac.now))
        // An admitted decision is recorded too, as enforced.
        #expect(try watch.admits(Mac.observation(freeBytes: 20 * Self.gib, fileBackedGiB: 60), bytes: 16 * Self.gib, now: Mac.now))
        let summary = watch.summary
        #expect(summary.decisions == 2 && summary.refusals == 1 && !summary.stoppedByCompressionOrSwap)
        #expect(summary.lastRefusal?.refusal?.hasPrefix("Test load needs 100.00 GiB of admissible memory") == true)
        let report = try #require(measurement.report)
        #expect(report.decisions == 2 && report.ruleWouldHaveRefused == 1 && report.refusalsNotEnforced == 1)
        #expect(report.decisionRows.map(\.ruleAdmitted) == [false, true])
        #expect(report.decisionRows.map(\.enforced) == [false, true])
        #expect(report.decisionRows[0].requiredBytes == 100 * Self.gib
            && report.decisionRows[0].admissibleBytes == 30 * Self.gib + 256 * Self.mib
            && report.decisionRows[0].countedReclaimableBytes == 30 * Self.gib)
        #expect(report.tightestDecision?.requiredBytes == 100 * Self.gib)
        #expect(report.fewestFreeDecision?.actualFreeBytes == 256 * Self.mib)
        #expect(report.samples.isEmpty && report.samplerFailure == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["schema"] as? String == "darkbloom_memory_gate_measurement_v3"
            && object["mode"] as? String == "measure"
            && object["policy"] as? String == QwenDenseStageLoadPolicy.identifier)
    }

    @Test func theGrowthGuardStillStopsTheLoad() throws {
        let (measurement, watch) = try Self.measuring()
        #expect(try watch.admits(Mac.observation(), bytes: 100 * Self.gib, now: Mac.now))
        let limit = QwenDenseStageLoadPolicy.maximumCompressedSinceFirstSampleBytes
        // At the limit the cache is still counted, so the refusal is for memory alone.
        #expect(try watch.admits(Mac.observation(compressedBytes: limit), bytes: 100 * Self.gib, now: Mac.now))
        // One page more: the kernel is taking anonymous memory, and the load stops.
        let stopped = Self.thrown {
            try watch.admits(Mac.observation(compressedBytes: limit + Self.page), bytes: 100 * Self.gib, now: Mac.now)
        }
        #expect(stopped?.contains("no file cache: 512 MiB was compressed") == true)
        #expect(watch.summary.stoppedByCompressionOrSwap)
        // The same for pages swapped out.
        let (_, second) = try Self.measuring()
        #expect(try second.admits(Mac.observation(), bytes: 100 * Self.gib, now: Mac.now))
        let swap = QwenDenseStageLoadPolicy.maximumSwappedOutSinceFirstSampleBytes
        #expect(Self.thrown {
            try second.admits(Mac.observation(swappedOutBytes: swap + Self.page), bytes: 100 * Self.gib, now: Mac.now)
        } != nil)
        let report = try #require(measurement.report)
        #expect(report.decisionRows.map(\.enforced) == [false, false, true])
        #expect(report.decisionRows[2].stoppedByCompressionOrSwap && report.refusalsNotEnforced == 2)
        // Harm does not stop a load whose free pages alone cover what it needs: the rule admits that itself.
        let (_, third) = try Self.measuring()
        #expect(try third.admits(Mac.observation(freeBytes: 20 * Self.gib, fileBackedGiB: 60), bytes: 16 * Self.gib, now: Mac.now))
        #expect(try third.admits(Mac.observation(freeBytes: 20 * Self.gib, fileBackedGiB: 60, compressedBytes: 2 * Self.gib),
                                 bytes: 16 * Self.gib, now: Mac.now))
    }

    @Test func recordingAloneChangesNoDecision() throws {
        let (measurement, watch) = try Self.measuring(.record)
        #expect(measurement.isEnabled && !measurement.waivesRefusals)
        // The mode is decided once for a process.
        #expect(throws: (any Error).self) { try measurement.enable(.measure, permittedBy: .permittedByExplicitFlag) }
        try measurement.enable(.record, permittedBy: .permittedByExplicitFlag)
        // The committed rule refuses, and the refusal stands.
        let refused = Self.thrown { try watch.admits(Mac.observation(), bytes: 100 * Self.gib, now: Mac.now) }
        #expect(refused?.hasPrefix("Test load needs 100.00 GiB of admissible memory and has 30.25 GiB") == true)
        // An admitted decision is admitted.
        #expect(try watch.admits(Mac.observation(freeBytes: 20 * Self.gib, fileBackedGiB: 60), bytes: 16 * Self.gib, now: Mac.now))
        let report = try #require(measurement.report)
        #expect(report.mode == "record" && report.decisions == 2 && report.ruleWouldHaveRefused == 1)
        #expect(report.refusalsNotEnforced == 0 && report.decisionRows.map(\.enforced) == [true, true])
        #expect(report.decisionRows.map(\.ruleAdmitted) == [false, true])
        #expect(watch.summary.refusals == 1)
    }

    @Test func whatALoadGaveUpAndCompressedIsRecordedAndDecidesNothing() throws {
        let (measurement, watch) = try Self.measuring()
        // First sample: 80 GiB of file cache, nothing given up yet.
        #expect(try watch.admits(Mac.observation(), bytes: 100 * Self.gib, now: Mac.now))
        // 40 GiB of cache given up and 40 GiB loaded since, with compression inside the committed limit.
        let limit = QwenDenseStageLoadPolicy.maximumCompressedSinceFirstSampleBytes
        #expect(try watch.admits(Mac.observation(fileBackedGiB: 40, compressedBytes: limit), bytes: 60 * Self.gib, now: Mac.now))
        // However much cache was given up, the committed limit is the limit.
        let over = Self.thrown {
            try watch.admits(Mac.observation(fileBackedGiB: 40, compressedBytes: limit + Self.page), bytes: 60 * Self.gib, now: Mac.now)
        }
        #expect(over?.contains("so the kernel is taking anonymous memory") == true)
        let rows = try #require(measurement.report).decisionRows
        #expect(rows.map(\.enforced) == [false, false, true])
        #expect(rows.map(\.fileCacheGivenUpBytes) == [0, 40 * Self.gib, 40 * Self.gib])
        #expect(rows[0].compressedPerMilleOfGivenUp == nil && rows[1].compressedPerMilleOfGivenUp == 12)
        // The requirement fell from 100 to 60 GiB: for a load, 40 GiB loaded so far.
        #expect(rows.map(\.requirementReducedBytes) == [0, 40 * Self.gib, 40 * Self.gib])
        #expect(rows[0].compressedPerMilleOfRequirementReduced == nil && rows[1].compressedPerMilleOfRequirementReduced == 12)
        // Cache that grew back is not a negative amount given up.
        let (grown, growing) = try Self.measuring()
        #expect(try growing.admits(Mac.observation(fileBackedGiB: 40), bytes: 100 * Self.gib, now: Mac.now))
        #expect(try growing.admits(Mac.observation(fileBackedGiB: 60), bytes: 100 * Self.gib, now: Mac.now))
        #expect(grown.report?.decisionRows.map(\.fileCacheGivenUpBytes) == [0, 0])
    }

    @Test func everyOtherRefusalIsStillEnforced() throws {
        // Warning pressure: no cache is counted, and the mode does not waive it.
        let (_, warning) = try Self.measuring()
        #expect(Self.thrown { try warning.admits(Mac.observation(pressure: 2), bytes: 16 * Self.gib, now: Mac.now) } != nil)
        // Critical pressure and a stale sample are not judged at all.
        let (measurement, unjudged) = try Self.measuring()
        #expect(Self.thrown { try unjudged.admits(Mac.observation(pressure: 4), bytes: 0, now: Mac.now) }
            == "Invalid, stale or pressured selected-stage resource observation")
        #expect(Self.thrown { try unjudged.admits(Mac.observation(), bytes: 0, now: 1_000 + 1_000_000_001) } != nil)
        #expect(measurement.report?.decisions == 0 && unjudged.summary.unjudged == 2)
        // Swap in use under warning pressure.
        let (_, swapped) = try Self.measuring()
        #expect(Self.thrown { try swapped.admits(Mac.observation(pressure: 2, swapBytes: Self.gib), bytes: 0, now: Mac.now) } != nil)
        // Fewer truly free pages than the floor: the kernel is not keeping up.
        let (_, starved) = try Self.measuring()
        let floor = Self.thrown { try starved.admits(Mac.observation(freeBytes: 8 * Self.mib), bytes: 100 * Self.gib, now: Mac.now) }
        #expect(floor?.contains("truly free, below the 16 MiB floor") == true)
        // More than the Mac has.
        let (_, larger) = try Self.measuring()
        #expect(Self.thrown { try larger.admits(Mac.observation(), bytes: 128 * Self.gib + 1, now: Mac.now) }
            == "Test load needs 128.00 GiB, more than this Mac's 128.00 GiB")
        // Exactly physical memory is the waivable verdict.
        #expect(try larger.admits(Mac.observation(), bytes: 128 * Self.gib, now: Mac.now))
    }
}
