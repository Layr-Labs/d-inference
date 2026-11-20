import Foundation

@main
enum BenchmarkPrefillPolicyCheck {
    struct Failure: Error { let message: String }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    static func main() throws {
        try require(try BenchmarkPrefillPolicy.parse(nil) == .serial, "Omitted policy changed serial default")
        try require(try BenchmarkPrefillPolicy.parse("serial_v1") == .serial, "Explicit serial rejected")
        try require(try BenchmarkPrefillPolicy.parse("one_chunk_lookahead_v1") == .oneChunkLookahead,
                    "Explicit lookahead rejected")
        // No trimming, case folding, raw-SPI spelling, version substitution or
        // prefix matching: a present invalid value must never become serial.
        let invalid = ["", " ", "\n", "serial", "oneChunkLookahead", "SERIAL_V1",
                       "one_chunk_lookahead_v2", "serial_v1 ", " serial_v1",
                       "one_chunk_lookahead_v1\n", "one_chunk_lookahead_v1\0",
                       "serial_v1,one_chunk_lookahead_v1", "unknown", String(repeating: "x", count: 4096)]
        for value in invalid {
            do {
                _ = try BenchmarkPrefillPolicy.parse(value)
                throw Failure(message: "Present invalid policy was accepted")
            } catch is BenchmarkPrefillPolicy.InvalidValue {
                // The rejected input is deliberately absent from diagnostics.
            }
        }
        print("Benchmark prefill policy: 3 accepted, 14 rejected; CPU parser only")
    }
}
