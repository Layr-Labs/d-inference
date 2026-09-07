import ArgumentParser
import MLXLMCommon
import Testing
@testable import darkbloom

@Suite("Quantized prefill benchmark control scope")
struct BenchmarkQuantizedPrefillOptionsTests {
    @Test func absentOptionKeepsDirectAndNativeDefaults() throws {
        let command = try Benchmark.parse([])
        #expect(command.quantizedPrefill == nil && command.kvQuantization == "native")
        #expect(try command.resolvedQuantizedPrefillMode() == .direct)
        #expect(command.quantizedPrefillOptionError() == nil)
    }

    @Test func approvedModesForwardTheTypedPolicy() throws {
        for mode in [["--sweep"], ["--scheduler-prefill"], ["--kv-quality-input", "/tmp/quality.json", "--model", "m"]] {
            for (selection, expected) in [("direct", PagedQuantizedPrefillMode.direct), ("opportunistic", .opportunisticSDPA)] {
                let command = try Benchmark.parse(mode + ["--kv-backend", "paged", "--kv-quantization", "int4",
                    "--quantized-prefill", selection])
                #expect(command.quantizedPrefillOptionError() == nil)
                #expect(try command.resolvedQuantizedPrefillMode() == expected)
            }
        }
    }

    @Test func ignoredPoliciesAndMalformedSelectionsRefuseBeforeLoading() throws {
        let option = ["--quantized-prefill", "opportunistic"]
        let packed = ["--kv-backend", "paged", "--kv-quantization", "int4"]
        for scope in [[], ["--parity"], ["--arrival-invariance"], ["--scheduler-prefill-decision"],
                      ["--teacher-forced-input", "/tmp/teacher.json", "--model", "m"]] {
            #expect(try Benchmark.parse(scope + packed + option).quantizedPrefillOptionError() != nil)
        }
        for arguments in [
            ["--sweep", "--quantized-prefill", "direct"],
            ["--sweep", "--kv-backend", "paged", "--kv-quantization", "native"] + option,
            ["--sweep", "--kv-backend", "contiguous", "--kv-quantization", "int4"] + option,
            ["--sweep"] + packed + ["--quantized-prefill", "typo"],
        ] {
            #expect(try Benchmark.parse(arguments).quantizedPrefillOptionError() != nil)
        }
    }
}
