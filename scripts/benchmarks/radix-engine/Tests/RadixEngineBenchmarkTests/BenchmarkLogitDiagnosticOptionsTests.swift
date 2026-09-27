import Testing
@_spi(Diagnostics) import MLXLMCommon
@testable import radix_engine

struct BenchmarkLogitDiagnosticOptionsTests {
    private let base = ["radix-engine", "/model", "/input", "/output", "cache-off", "mtp-on", "paged", "ssd", "ephemeral-key"]

    @Test func ordinaryInvocationHasNoDiagnosticConfiguration() throws {
        #expect(try BenchmarkOptions(base).logitDiagnostic == nil)
    }

    @Test func explicitCapturePreservesBackendAndMTP() throws {
        let options = try BenchmarkOptions(base + [
            "--logit-diagnostic-position", "53", "--logit-diagnostic-candidates", "7244,2919"])
        let diagnostic = try #require(options.logitDiagnostic)
        #expect(diagnostic.requestID == 2)
        #expect(diagnostic.outputIndex == 53)
        #expect(diagnostic.candidateIDs == [7244, 2919])
        #expect(options.mtpEnabled)
        #expect(options.backend.rawValue == "paged")
        #expect(!options.cacheEnabled)
    }

    @Test func invalidOrPartialDiagnosticCannotSilentlyRun() {
        let invalid = [
            ["--logit-diagnostic-position", "53"],
            ["--logit-diagnostic-candidates", "7244,2919"],
            ["--logit-diagnostic-position", "-1", "--logit-diagnostic-candidates", "1,2"],
            ["--logit-diagnostic-position", "53", "--logit-diagnostic-candidates", "1,2,3"],
            ["--logit-diagnostic-position", "53", "--logit-diagnostic-candidates", "1,1"],
            ["--logit-diagnostic-position", "53", "--logit-diagnostic-candidates", "1,"],
            ["--logit-diagnostic-position", "53", "--logit-diagnostic-candidates", "1,2", "--concurrency", "2"],
        ]
        for flags in invalid {
            #expect(throws: (any Error).self) { try BenchmarkOptions(base + flags) }
        }
    }
}
