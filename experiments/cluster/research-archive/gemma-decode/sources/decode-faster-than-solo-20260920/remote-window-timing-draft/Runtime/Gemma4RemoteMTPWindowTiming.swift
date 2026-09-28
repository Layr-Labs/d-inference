import Foundation

/// Same-target-process wall clocks, including waiting for actual remote ACKs.
/// No remote clock subtraction, model roots, callbacks, evaluation or I/O.
struct Gemma4RemoteMTPWindowTiming: Encodable {
    enum Kind: String, Encodable { case prime, verification, tail }
    let ordinal: Int, kind: Kind, width: Int, accepted: Int
    var totalNanoseconds: UInt64 = 0
    var proposalFillNanoseconds: UInt64 = 0, lookaheadGrantNanoseconds: UInt64 = 0
    var targetNanoseconds: UInt64 = 0, selectionNanoseconds: UInt64 = 0
    var proposalDrainNanoseconds: UInt64 = 0, reconcileNanoseconds: UInt64 = 0
    var resolutionACKNanoseconds: UInt64 = 0, branchRetirementNanoseconds: UInt64 = 0
    var conditioningReseedNanoseconds: UInt64 = 0, finishNanoseconds: UInt64 = 0
    var targetPrepareNanoseconds: UInt64 = 0, targetAdmissionNanoseconds: UInt64 = 0
    var targetExecutionNanoseconds: UInt64 = 0
}

struct Gemma4RemoteMTPVerificationTiming {
    let lookaheadGrantNanoseconds: UInt64, targetNanoseconds: UInt64, selectionNanoseconds: UInt64
    let proposalDrainNanoseconds: UInt64, reconcileNanoseconds: UInt64, resolutionACKNanoseconds: UInt64
}

struct Gemma4RemoteMTPControlDelta: Encodable {
    let sends: UInt64, receives: UInt64, completedOperations: UInt64
    let entryResourceChecks: UInt64, exitResourceChecks: UInt64, innerLifetimeChecks: UInt64

    init(before: Gemma4MTPControlCounters.Snapshot, after: Gemma4MTPControlCounters.Snapshot) throws {
        func difference(_ end: UInt64, _ start: UInt64) throws -> UInt64 {
            guard end >= start else { throw Gemma4RemoteMTPTiming.Failure.counterRegression }
            return end-start
        }
        sends = try difference(after.sends,before.sends)
        receives = try difference(after.receives,before.receives)
        completedOperations = try difference(after.completedOperations,before.completedOperations)
        entryResourceChecks = try difference(after.entryResourceChecks,before.entryResourceChecks)
        exitResourceChecks = try difference(after.exitResourceChecks,before.exitResourceChecks)
        innerLifetimeChecks = try difference(after.innerLifetimeChecks,before.innerLifetimeChecks)
    }
}

struct Gemma4RemoteMTPRequestTiming: Encodable {
    let schema = "gemma4_remote_mtp_target_window_timings_v1"
    let maximumRecords = 128
    let sameTargetProcessWallClock = true, assistantGPUTimeMeasured = false
    let overlappingPhaseTotalsAreAdditive = false
    let requestControlExcludesCohortBarriers = true
    let targetSubphasesIncludedInTargetTotal = true
    let windowTotalsIncludeUnclassifiedBookkeeping = true
    let windows: [Gemma4RemoteMTPWindowTiming]
    let finalFinishNanoseconds: UInt64
    let controlDelta: Gemma4RemoteMTPControlDelta
}

enum Gemma4RemoteMTPTiming {
    enum Failure: Error { case windowBound, counterRegression }
    static func append(_ row: Gemma4RemoteMTPWindowTiming,
                       to rows: inout [Gemma4RemoteMTPWindowTiming], outputCount: Int) throws {
        guard (2...128).contains(outputCount), rows.count < 128, rows.count < outputCount-1,
              row.ordinal == rows.count, (1...3).contains(row.width),
              (0..<row.width).contains(row.accepted),
              (row.kind == .verification || (row.width == 1 && row.accepted == 0)) else {
            throw Failure.windowBound
        }
        rows.append(row)
    }
}
