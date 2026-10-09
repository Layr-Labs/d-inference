import Testing
@testable import radix_engine

@Suite struct BenchmarkPromptAuditOptionsTests {
    private let base = ["radix-engine", "/model", "/input.json", "/output.json", "cache-off",
                        "mtp-off", "contiguous", "ssd", "ephemeral-key"]
    @Test func auditIsExplicitAndCannotMixWithGPUProbe() throws {
        #expect(try BenchmarkOptions(base + ["--prompt-audit-only"]).promptAuditOnly)
        #expect(throws: (any Error).self) {
            try BenchmarkOptions(base + ["--prompt-audit-only", "--native-kv-probe-only"])
        }
        #expect(throws: (any Error).self) {
            try BenchmarkOptions(base + ["--prompt-audit-only", "--prompt-audit-only"])
        }
        #expect(throws: (any Error).self) {
            try BenchmarkOptions(base + ["--prompt-audit-only", "--concurrency", "2"])
        }
    }

    #if RADIX_CANDIDATE
    @Test func injectedCandidateEnvironmentRequiresVerifiedBoundedHeaders() throws {
        let environment = ["DARKBLOOM_CBV2_SELECTIVE_KV": "instruction-half"]
        func input(prefix: Int?) -> Input {
            Input(name: "header", kind: "test", tokens: Array(repeating: 1, count: 256),
                  maxTokens: 1, instructionPrefixTokens: prefix)
        }
        for prefix: Int? in [nil, 0, 129] {
            #expect(throws: (any Error).self) {
                try BenchmarkPromptAudit.requireInstructionPrefixCoverage(
                    [input(prefix: prefix)], modelType: "gpt_oss", environment: environment)
            }
        }
        try BenchmarkPromptAudit.requireInstructionPrefixCoverage(
            [input(prefix: 128)], modelType: "gpt_oss", environment: environment)
        #expect(throws: (any Error).self) {
            try BenchmarkPromptAudit.requireInstructionPrefixCoverage(
                [], modelType: "gpt_oss", environment: environment)
        }
        #expect(throws: (any Error).self) {
            try BenchmarkPromptAudit.requireInstructionPrefixCoverage(
                [input(prefix: 128)], modelType: "gemma4", environment: environment)
        }
        // An explicitly disabled/ordinary arm must not inherit the process mode.
        try BenchmarkPromptAudit.requireInstructionPrefixCoverage(
            [input(prefix: nil)], modelType: "gpt_oss", environment: [:])
        try BenchmarkPromptAudit.requireInstructionPrefixCoverage(
            [input(prefix: nil)], modelType: "gpt_oss",
            environment: ["DARKBLOOM_CBV2_SELECTIVE_KV": "half"])
    }
    #endif
}
