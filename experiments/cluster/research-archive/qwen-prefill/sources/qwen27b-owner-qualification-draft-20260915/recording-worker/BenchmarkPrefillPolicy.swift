/// Private benchmark configuration; no environment lookup or native dependency.
/// External spellings are deliberately separate from the experimental SPI's
/// raw values. An omitted value preserves the original serial behavior.
enum BenchmarkPrefillPolicy: String, Sendable {
    case serial = "serial_v1"
    case oneChunkLookahead = "one_chunk_lookahead_v1"

    static let environmentName = "DARKBLOOM_BENCHMARK_PREFILL_POLICY"

    struct InvalidValue: Error, CustomStringConvertible {
        var description: String {
            "DARKBLOOM_BENCHMARK_PREFILL_POLICY must be serial_v1 or one_chunk_lookahead_v1"
        }
    }

    static func parse(_ value: String?) throws -> Self {
        guard let value else { return .serial }
        guard let policy = Self(rawValue: value) else { throw InvalidValue() }
        return policy
    }
}
