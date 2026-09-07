import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Benchmark KV quantization selection")
struct BenchmarkKVQuantizationOptionsTests {
    @Test func nativeRemainsTheDefault() throws {
        let command = try Benchmark.parse([])
        #expect(command.kvQuantizationOptionError() == nil)
        #expect(try command.resolvedKVQuantizationSelection() == .native)
    }

    @Test(arguments: ["int4", "k8v4", "int8"])
    func explicitPagedMeasurementModes(mode: String) throws {
        for option in ["--sweep", "--scheduler-prefill", "--arrival-invariance"] {
            let command = try Benchmark.parse([option, "--kv-backend", "paged", "--kv-quantization", mode])
            #expect(command.kvQuantizationOptionError() == nil)
        }
        let command = try Benchmark.parse(["--teacher-forced-input", "/tmp/input.json", "--kv-backend", "paged", "--kv-quantization", mode])
        #expect(command.kvQuantizationOptionError() == nil)
    }

    @Test func ignoredOrAmbiguousSelectionsRefuseBeforeLoading() throws {
        for arguments in [
            ["--sweep", "--kv-quantization", "int4"],
            ["--sweep", "--kv-backend", "contiguous", "--kv-quantization", "int4"],
            ["--parity", "--kv-backend", "paged", "--kv-quantization", "int4"],
            ["--kv-backend", "paged", "--kv-quantization", "int4"],
            ["--sweep", "--kv-backend", "paged", "--kv-quantization", "int44"],
        ] {
            #expect(try Benchmark.parse(arguments).kvQuantizationOptionError() != nil)
        }
    }
}
