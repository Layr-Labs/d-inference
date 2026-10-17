import Foundation

@main
struct RecordChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw RecordFixtureError.failed("fixed vector path required") }
        let vectorURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let groups: [(String, () throws -> Void)] = [
            ("independent Python/OpenSSL bidirectional fixed vectors", { try checkIndependentVectors(vectorURL) }),
            ("closed configuration and scope", checkConfigurationRefusals),
            ("setup/request bidirectional round trips", checkRoundTrips),
            ("tamper/truncation/unknown framing and caps", checkTamperAndFraming),
            ("key/epoch/plan/membership/request/type/geometry/direction binding", checkBindingAndContext),
            ("replay/skip and record/cumulative byte exhaustion", checkReplayAndBudgets),
            ("concurrent operation and invalidation publication", checkConcurrentAndInvalidation),
            ("canonical domains and monotonic nonce counters", checkCanonicalAndCounterBoundaries),
        ]
        for (label, body) in groups { try body(); print("PASS " + label) }
        print("PASS 8 authenticated-record CPU groups; no native/network/membership qualification")
    }
}
