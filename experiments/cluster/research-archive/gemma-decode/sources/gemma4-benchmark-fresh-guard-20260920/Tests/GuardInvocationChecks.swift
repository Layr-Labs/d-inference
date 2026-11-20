import Foundation

private typealias Invocation = Gemma4BenchmarkGuardInvocation
private func require(_ value: @autoclosure () -> Bool) { precondition(value(), "Invocation control failed") }
private func refuses(_ expected: Invocation.Failure, _ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected refusal") }
    catch let error as Invocation.Failure { require(error == expected) }
    catch { preconditionFailure("Wrong refusal: \(error)") }
}
private func make(_ mode: Invocation.Mode = .combined) -> Invocation {
    .init(mode: mode, deadline: 2_000, created: 100, maximumAge: 1_000)
}
private func accept(_ value: inout Invocation, _ consumer: Invocation.Consumer, now: UInt64 = 200) throws {
    try value.accept(consumer, started: 110, completed: 120, expectedDeadline: 2_000, now: now)
}

@main private struct GuardInvocationChecks {
    static func main() throws {
        require(Invocation.schema == "gemma4_invocation_fresh_observation_v1")
        var shared = make()
        try accept(&shared, .entry); try accept(&shared, .owner); try accept(&shared, .entry)
        try shared.finish(expectedDeadline: 2_000, now: 210)
        refuses(.closed) { try shared.preflight(.entry, expectedDeadline: 2_000, now: 211) }
        print("PASS exact-three-consumers-then-closed")

        for (mode, consumer) in [(Invocation.Mode.entry, Invocation.Consumer.entry), (.owner, .owner)] {
            var value = make(mode); require(value.expectedUses == 1)
            try accept(&value, consumer); try value.finish(expectedDeadline: 2_000, now: 210)
            refuses(.closed) { try value.preflight(consumer, expectedDeadline: 2_000, now: 210) }
        }
        print("PASS standalone-checks-are-one-use")

        var order = make()
        refuses(.wrongConsumer) { try accept(&order, .owner) }
        try accept(&order, .entry)
        refuses(.wrongConsumer) { try accept(&order, .entry) }
        try accept(&order, .owner); try accept(&order, .entry)
        refuses(.wrongConsumer) { try accept(&order, .entry) }
        print("PASS skipped-duplicated-and-extra-consumers-refused")

        var incomplete = make(); try accept(&incomplete, .entry)
        refuses(.incomplete) { try incomplete.finish(expectedDeadline: 2_000, now: 210) }
        incomplete.close()
        refuses(.closed) { try accept(&incomplete, .owner) }
        print("PASS incomplete-and-unwound-scope-refused")

        let deadline = Invocation(mode: .entry, deadline: 300, created: 100, maximumAge: 1_000)
        refuses(.expired) { try deadline.preflight(.entry, expectedDeadline: 300, now: 300) }
        refuses(.invalidConfiguration) { try deadline.preflight(.entry, expectedDeadline: 301, now: 200) }
        let reverse = make()
        refuses(.expired) { try reverse.preflight(.entry, expectedDeadline: 2_000, now: 99) }
        print("PASS-original-deadline-binding-and-clock-order")

        var age = make()
        try age.preflight(.entry, expectedDeadline: 2_000, now: 1_100)
        refuses(.expired) { try age.preflight(.entry, expectedDeadline: 2_000, now: 1_101) }
        refuses(.staleObservation) { try age.accept(.entry, started: 99, completed: 120, expectedDeadline: 2_000, now: 200) }
        refuses(.staleObservation) { try age.accept(.entry, started: 130, completed: 120, expectedDeadline: 2_000, now: 200) }
        refuses(.staleObservation) { try age.accept(.entry, started: 110, completed: 201, expectedDeadline: 2_000, now: 200) }
        print("PASS-observation-must-originate-inside-current-scope")

        var configuration = Invocation(mode: .entry, deadline: 100, created: 100, maximumAge: 1_000)
        refuses(.invalidConfiguration) { try configuration.preflight(.entry, expectedDeadline: 100, now: 100) }
        configuration = .init(mode: .entry, deadline: 2_000, created: 100, maximumAge: 0)
        refuses(.invalidConfiguration) { try configuration.preflight(.entry, expectedDeadline: 2_000, now: 100) }
        var maximum = Invocation(mode: .entry, deadline: .max, created: .max-100, maximumAge: 100)
        try maximum.accept(.entry, started: .max-90, completed: .max-80, expectedDeadline: .max, now: .max-1)
        try maximum.finish(expectedDeadline: .max, now: .max-1)
        print("PASS-invalid-configuration-and-overflow-safe-bounds")

        var last = make(); try accept(&last, .entry); try accept(&last, .owner); try accept(&last, .entry)
        refuses(.expired) { try last.finish(expectedDeadline: 2_000, now: 1_101) }
        last.close()
        var next = Invocation(mode: .entry, deadline: 3_000, created: 1_200, maximumAge: 1_000)
        refuses(.staleObservation) { try next.accept(.entry, started: 110, completed: 120, expectedDeadline: 3_000, now: 1_300) }
        try next.accept(.entry, started: 1_201, completed: 1_202, expectedDeadline: 3_000, now: 1_300)
        try next.finish(expectedDeadline: 3_000, now: 1_300)
        print("PASS-final-age-check-and-cross-invocation-refusal")
        let maximumRecords = Gemma4BenchmarkGuardMetrics.Snapshot(records:
            Gemma4BenchmarkGuardMetrics.Kind.allCases.map {
                .init(category: $0.label, count: .max, nanoseconds: .max, nestedLogicalGuardNanoseconds: .max)
            }, overflow: false)
        struct Envelope: Encodable {
            let policy = Invocation.schema
            let cohort: Gemma4BenchmarkGuardMetrics.Snapshot
            let samples: [Gemma4BenchmarkGuardMetrics.Sample]
        }
        let encoded = try JSONEncoder().encode(Envelope(cohort: maximumRecords,
            samples: Array(repeating: .init(prefill: maximumRecords, decode: maximumRecords), count: 4)))
        let metricStorage = 18 * 9 * MemoryLayout<Gemma4BenchmarkGuardMetrics.Record>.stride
        // One fixed holder, scalar OS snapshot/temporary copies and the bounded
        // ISO timestamp string; no tensor, packet, thread or record array.
        let scopeStorage = 2_048 + MemoryLayout<Invocation>.stride
        require(encoded.count + metricStorage + scopeStorage < Gemma4BenchmarkGuardMetrics.hostAllowanceBytes)
        print("PASS-within-existing-instrumentation-host-allowance")
        print("PASS 9 invocation controls; Foundation only; no OS observations")
    }
}
