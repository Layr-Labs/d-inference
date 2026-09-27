import Testing
@testable import radix_engine

struct BenchmarkGemmaVerifierOptionsTests {
    private let base = ["radix-engine", "/model", "/input", "/output", "cache-off", "mtp-on", "paged", "ssd"]
    private let grant = ["--production-kv-grant", "--expected-model-sha256", String(repeating: "a", count: 64)]

    @Test func defaultDoesNotSelectAnOverride() throws {
        let options = try BenchmarkOptions(base)
        #expect(options.gemmaMTPVerification == nil && options.gemmaProjectionTokens == nil)
    }

    #if RADIX_CANDIDATE
    @Test func validSelectionsPreserveNormalSettings() throws {
        for mode in ["automatic", "serial_target"] {
            let options = try BenchmarkOptions(base + grant + ["--gemma-mtp-verification", mode])
            #expect(options.gemmaMTPVerification == mode)
            #expect(options.mtpEnabled && options.productionKVGrant && !options.cacheEnabled)
            #expect(options.concurrency == 1 && options.backend.rawValue == "paged")
        }
        let options = try BenchmarkOptions(base + grant + ["--gemma-mtp-verification", "automatic",
            "--gemma-projection-tokens", "529,62203"])
        #expect(options.gemmaProjectionTokens == [529, 62203])
    }

    @Test func refusesUnscopedAndMalformedSelections() {
        for flag in [["--gemma-mtp-verification", "rectangular"],
            ["--gemma-mtp-verification", "serial_target", "--concurrency", "2"],
            ["--gemma-mtp-verification", "serial_target", "--native-kv-probe-only"],
            ["--gemma-mtp-verification", "serial_target", "--kv-budget-gib", "16"],
            ["--gemma-projection-tokens", "529,62203"]] {
            #expect(throws: (any Error).self) { try BenchmarkOptions(base + grant + flag) }
        }
        for raw in ["", "529", "529,62203,7", "-1,3", "1,", "01,3", "1,2147483648"] {
            #expect(throws: (any Error).self) {
                try BenchmarkOptions(base + grant + ["--gemma-mtp-verification", "automatic", "--gemma-projection-tokens", raw])
            }
        }
        for (index, value) in [(4, "cache-on"), (5, "mtp-off"), (6, "auto"), (7, "resident")] {
            var changed = base
            changed[index] = value
            #expect(throws: (any Error).self) {
                try BenchmarkOptions(changed + grant + ["--gemma-mtp-verification", "automatic"])
            }
        }
    }
    #else
    @Test func baselineRefusesExplicitControls() {
        #expect(throws: (any Error).self) {
            try BenchmarkOptions(base + grant + ["--gemma-mtp-verification", "automatic"])
        }
    }
    #endif
}
