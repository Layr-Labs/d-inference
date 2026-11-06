import Foundation

/// Serialized, fixed-size CPU counters. No model, OS reader, file or timer task.
/// Durations are inclusive; different categories MUST NOT be added together.
final class Gemma4BenchmarkGuardMetrics {
    static let hostAllowanceBytes = 32_768
    static let observationPolicy = "gemma4_control_operation_resource_boundaries_v1"
    enum Kind: Int, CaseIterable {
        case logicalGuard, entryGuard, ownerGuard, environmentGuard
        case osSnapshot, nativeSnapshot, outerNativeFault
        case wireSendCompleted, wireReceiveCompleted
        case resourceGate, faultDeadlineCheck
        var label: String {
            switch self {
            case .logicalGuard: return "logicalGuard"
            case .entryGuard: return "entryGuard"
            case .ownerGuard: return "ownerGuard"
            case .environmentGuard: return "environmentGuard"
            case .osSnapshot: return "osSnapshot"
            case .nativeSnapshot: return "nativeSnapshot"
            case .outerNativeFault: return "outerNativeFault"
            case .wireSendCompleted: return "wireSendCompleted"
            case .wireReceiveCompleted: return "wireReceiveCompleted"
            case .resourceGate: return "resourceGate"
            case .faultDeadlineCheck: return "faultDeadlineCheck"
            }
        }
    }
    struct Record: Encodable, Equatable {
        let category: String
        var count: UInt64 = 0, nanoseconds: UInt64 = 0
        var nestedLogicalGuardNanoseconds: UInt64 = 0
    }
    struct Snapshot: Encodable {
        let schema = "gemma4_guard_wall_counters_v2"
        let records: [Record]
        let overflow: Bool
        let sameProcessClock = true, categoriesAreInclusive = true
        let extraOSReads = 0, extraNativeEvaluations = 0
        let observerOverheadIncludedInRequestTiming = true
        // Full combined runtime guards and cheap control-internal guards are
        // counted separately. OS/native snapshots include standalone gates too.
        let resourceGateCountsCombinedChecksOnly = true
        let faultDeadlineCheckReadsResources = false
    }
    struct Sample: Encodable {
        let prefill: Snapshot, decode: Snapshot
        let boundary = "request-start_to_first-token-agreement_and_first-to-last-agreement"
    }
    private let clock: () -> UInt64
    private var rows = Kind.allCases.map { Record(category: $0.label) }
    private var overflow = false

    init(clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.clock = clock
    }
    private func index(_ kind: Kind) -> Int { kind.rawValue }
    private func sum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        if result.overflow { overflow = true; return .max }
        return result.partialValue
    }
    func record(_ kind: Kind, elapsed: UInt64, nestedGuard: UInt64 = 0) {
        let i = index(kind)
        rows[i].count = sum(rows[i].count, 1)
        rows[i].nanoseconds = sum(rows[i].nanoseconds, elapsed)
        rows[i].nestedLogicalGuardNanoseconds = sum(rows[i].nestedLogicalGuardNanoseconds, nestedGuard)
    }
    func measure<T>(_ kind: Kind, _ body: () throws -> T) rethrows -> T {
        let start = clock(), guardBefore = rows[index(.logicalGuard)].nanoseconds
        defer {
            let end = clock(), guardAfter = rows[index(.logicalGuard)].nanoseconds
            if end < start || guardAfter < guardBefore { overflow = true }
            record(kind, elapsed: end >= start ? end-start : 0,
                   nestedGuard: kind == .logicalGuard ? 0 : (guardAfter >= guardBefore ? guardAfter-guardBefore : 0))
        }
        return try body()
    }
    func observeOS(_ elapsed: UInt64) { record(.osSnapshot, elapsed: elapsed) }
    func snapshot() -> Snapshot { .init(records: rows, overflow: overflow) }

    static func difference(_ end: Snapshot, _ start: Snapshot) -> Snapshot {
        var invalid = end.overflow || start.overflow
        let rows = zip(end.records, start.records).map { end, start in
            if end.category != start.category || end.count < start.count
                || end.nanoseconds < start.nanoseconds || end.nestedLogicalGuardNanoseconds < start.nestedLogicalGuardNanoseconds {
                invalid = true
                return Record(category: end.category)
            }
            return Record(category: end.category, count: end.count-start.count,
                          nanoseconds: end.nanoseconds-start.nanoseconds,
                          nestedLogicalGuardNanoseconds: end.nestedLogicalGuardNanoseconds-start.nestedLogicalGuardNanoseconds)
        }
        if rows.count != Kind.allCases.count { invalid = true }
        return .init(records: rows, overflow: invalid)
    }
}
