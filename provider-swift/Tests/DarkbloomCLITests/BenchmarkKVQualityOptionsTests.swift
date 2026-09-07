import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Free-generation benchmark CLI scope")
struct BenchmarkKVQualityOptionsTests {
    private let base = ["--kv-quality-input", "/tmp/cases.json", "--model", "catalog-model", "--kv-backend", "paged"]
    @Test func exactArtifactDirectoryAndQuantizationAreSupported() throws {
        let parsed = try Benchmark.parse(base + ["--model-directory", "/tmp/view", "--kv-quantization", "int4"])
        #expect(parsed.benchmarkModeConflict() == nil)
        #expect(parsed.kvQualityOptionError() == nil && parsed.modelDirectoryOptionError() == nil)
        #expect(parsed.kvQuantizationOptionError() == nil)
    }
    @Test func ignoredAndAmbiguousOptionsRefuseBeforeLoading() throws {
        for mode in ["--sweep", "--parity", "--scheduler-prefill", "--arrival-invariance", "--scheduler-prefill-decision"] {
            #expect(try Benchmark.parse(base + [mode]).benchmarkModeConflict() != nil)
        }
        #expect(try Benchmark.parse(base + ["--teacher-forced-input", "/tmp/teacher.json"]).benchmarkModeConflict() != nil)
        for options in [["--assistant-model", "draft"], ["--output", "/tmp/out"],
            ["--expected-model-aggregate-sha256", String(repeating: "a", count: 64)]] {
            #expect(try Benchmark.parse(base + options).kvQualityOptionError() != nil)
        }
        #expect(try Benchmark.parse(["--kv-quality-input", "/tmp/cases.json"]).kvQualityOptionError() != nil)
        #expect(try Benchmark.parse(["--kv-quality-input", "/tmp/cases.json", "--model", "m"]).kvQualityOptionError() != nil)
        #expect(try Benchmark.parse([]).kvQualityInput == nil)
    }
}
