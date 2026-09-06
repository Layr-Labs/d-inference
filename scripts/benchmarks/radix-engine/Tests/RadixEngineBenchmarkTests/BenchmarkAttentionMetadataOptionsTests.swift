import Testing
@_spi(Diagnostics) import MLXLMCommon
@testable import radix_engine

struct BenchmarkAttentionMetadataOptionsTests {
    private let base = ["radix-engine", "/model", "/input", "/output", "cache-off", "mtp-off", "paged", "ssd", "ephemeral-key"]

    @Test func defaultIsNilAndExplicitSelectionKeepsBackendAndCachePolicy() throws {
        #expect(try BenchmarkOptions(base).attentionMetadata == nil)
        for backend in ["paged", "contiguous"] {
            var args = base
            args[6] = backend
            let options = try BenchmarkOptions(args + ["--attention-metadata-position", "62"])
            let config = try #require(options.attentionMetadata)
            #expect(config.requestID == 2 && config.outputIndex == 62)
            #expect(options.backend.rawValue == backend)
            #expect(!options.mtpEnabled && !options.cacheEnabled)
            #expect(options.logitDiagnostic == nil)
        }
    }

    @Test func combinedMetadataAndLogitSelectionPreservesServingOptions() throws {
        for backend in ["paged", "contiguous"] {
            var args = base
            args[6] = backend
            let options = try BenchmarkOptions(args + [
                "--attention-metadata-position", "62",
                "--logit-diagnostic-position", "62", "--logit-diagnostic-candidates", "1928,6829",
            ])
            let metadata = try #require(options.attentionMetadata)
            let logits = try #require(options.logitDiagnostic)
            #expect(metadata.requestID == 2 && metadata.outputIndex == 62)
            #expect(metadata.maximumRecords == 64)
            #expect(logits.requestID == metadata.requestID && logits.outputIndex == metadata.outputIndex)
            #expect(logits.candidateIDs == [1928, 6829])
            #expect(options.backend.rawValue == backend)
            #expect(!options.mtpEnabled && !options.cacheEnabled)
        }
    }

    @Test func unsupportedModesAndInvalidSelectionsAreRejected() {
        var mtp = base
        mtp[5] = "mtp-on"
        var resident = base
        resident[7] = "resident"
        for args in [mtp, resident, base + ["--concurrency", "2"],
                     base + ["--concurrency", "4"], base + ["--native-kv-probe-only"]] {
            #expect(throws: (any Error).self) {
                try BenchmarkOptions(args + ["--attention-metadata-position", "62"])
            }
        }
        for position in ["0", "-1", "1000001", "x"] {
            #expect(throws: (any Error).self) {
                try BenchmarkOptions(base + ["--attention-metadata-position", position])
            }
        }
        #expect(throws: (any Error).self) {
            try BenchmarkOptions(base + ["--attention-metadata-position", "62", "--attention-metadata-position", "62"])
        }
    }
}
