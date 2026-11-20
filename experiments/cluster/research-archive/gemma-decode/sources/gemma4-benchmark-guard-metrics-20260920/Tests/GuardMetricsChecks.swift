import Foundation

private final class Clock {
    var value: UInt64 = 0
    func now() -> UInt64 { value }
}
private enum Failure: Error { case original }
private func record(_ snapshot: Gemma4BenchmarkGuardMetrics.Snapshot, _ kind: Gemma4BenchmarkGuardMetrics.Kind) -> Gemma4BenchmarkGuardMetrics.Record {
    snapshot.records[kind.rawValue]
}
private func require(_ value: @autoclosure () -> Bool) {
    precondition(value(), "Guard metric control failed")
}

@main private struct GuardMetricsChecks {
    static func main() throws {
        let clock = Clock(), metrics = Gemma4BenchmarkGuardMetrics(clock: { 0 })
        require(metrics.snapshot().records.count == 9)
        require(metrics.snapshot().records.allSatisfy { $0.count == 0 && $0.nanoseconds == 0 })
        print("PASS empty-fixed-buckets")

        let nested = Gemma4BenchmarkGuardMetrics(clock: clock.now)
        let value: Int = nested.measure(.wireSendCompleted) {
            clock.value += 5
            nested.measure(.logicalGuard) { clock.value += 10 }
            clock.value += 5
            return 42
        }
        require(value == 42)
        let first = nested.snapshot()
        require(record(first, .wireSendCompleted).nanoseconds == 20)
        require(record(first, .wireSendCompleted).nestedLogicalGuardNanoseconds == 10)
        require(record(first, .logicalGuard).nanoseconds == 10)
        print("PASS inclusive-wire-with-nested-guard")

        do {
            try nested.measure(.ownerGuard) { clock.value += 7; throw Failure.original }
            preconditionFailure("Expected original error")
        } catch Failure.original {}
        require(record(nested.snapshot(), .ownerGuard).count == 1)
        require(record(nested.snapshot(), .ownerGuard).nanoseconds == 7)
        print("PASS original-error-precedence")

        nested.observeOS(11); nested.observeOS(13)
        require(record(nested.snapshot(), .osSnapshot).count == 2)
        require(record(nested.snapshot(), .osSnapshot).nanoseconds == 24)
        print("PASS unique-os-callback-count")

        let delta = Gemma4BenchmarkGuardMetrics.difference(nested.snapshot(), first)
        require(record(delta, .wireSendCompleted).count == 0)
        require(record(delta, .ownerGuard).count == 1)
        require(record(delta, .osSnapshot).nanoseconds == 24)
        require(!delta.overflow)
        require(Gemma4BenchmarkGuardMetrics.difference(first, nested.snapshot()).overflow)
        print("PASS request-boundary-deltas")

        let overflow = Gemma4BenchmarkGuardMetrics(clock: clock.now)
        overflow.record(.osSnapshot, elapsed: .max)
        overflow.record(.osSnapshot, elapsed: 1)
        require(overflow.snapshot().overflow)
        require(record(overflow.snapshot(), .osSnapshot).nanoseconds == .max)
        let reversed = Gemma4BenchmarkGuardMetrics(clock: clock.now)
        reversed.measure(.entryGuard) { clock.value -= 1 }
        require(reversed.snapshot().overflow)
        print("PASS overflow-and-clock-regression-are-visible")

        let maximum = Gemma4BenchmarkGuardMetrics.Snapshot(records:
            Gemma4BenchmarkGuardMetrics.Kind.allCases.map {
                .init(category: $0.label, count: .max, nanoseconds: .max, nestedLogicalGuardNanoseconds: .max)
            }, overflow: false)
        struct Envelope: Encodable {
            let cohort: Gemma4BenchmarkGuardMetrics.Snapshot
            let samples: [Gemma4BenchmarkGuardMetrics.Sample]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Envelope(cohort: maximum,
            samples: Array(repeating: .init(prefill: maximum, decode: maximum), count: 4)))
        let scalarStorage = 18 * 9 * MemoryLayout<Gemma4BenchmarkGuardMetrics.Record>.stride
        require(bytes.count + scalarStorage < Gemma4BenchmarkGuardMetrics.hostAllowanceBytes)
        print("PASS bounded-four-request-report-and-scalar-storage")
        print("PASS 7 guard metric groups; Foundation only")
    }
}
