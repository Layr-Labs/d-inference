import Testing
@_spi(Diagnostics) import MLXLMCommon
@testable import radix_engine

struct BenchmarkAttentionPacketOptionsTests {
    private let base = ["radix-engine", "/model", "/input", "/output", "cache-off", "mtp-off", "paged", "ssd", "ephemeral-key"]

    @Test func defaultIsNilAndAllDiagnosticsKeepIndependentSelections() throws {
        #expect(try BenchmarkOptions(base).attentionPacket == nil)
        for backend in ["paged", "contiguous"] {
            var args = base
            args[6] = backend
            let options = try BenchmarkOptions(args + [
                "--attention-packet-position", "63", "--attention-packet-layer", "9",
                "--attention-metadata-position", "62",
                "--logit-diagnostic-position", "61", "--logit-diagnostic-candidates", "1928,6829",
            ])
            let packet = try #require(options.attentionPacket)
            #expect(packet.requestID == 2 && packet.outputIndex == 63 && packet.storageLayerIndex == 9)
            #expect(packet.maximumBytes == 32 * 1_024 * 1_024)
            #expect(options.attentionMetadata?.outputIndex == 62)
            #expect(options.logitDiagnostic?.outputIndex == 61)
            #expect(options.backend.rawValue == backend && !options.mtpEnabled && !options.cacheEnabled)
        }
    }

    @Test func invalidAndPartialPacketOptionsAreRejected() {
        let packet = ["--attention-packet-position", "62", "--attention-packet-layer", "9"]
        var mtp = base
        mtp[5] = "mtp-on"
        var resident = base
        resident[7] = "resident"
        for args in [mtp, resident, base + ["--concurrency", "2"], base + ["--native-kv-probe-only"]] {
            #expect(throws: (any Error).self) { try BenchmarkOptions(args + packet) }
        }
        for flags in [Array(packet.prefix(2)), Array(packet.suffix(2)), packet + packet,
                      ["--attention-packet-position", "0", "--attention-packet-layer", "9"],
                      ["--attention-packet-position", "62", "--attention-packet-layer", "1024"]] {
            #expect(throws: (any Error).self) { try BenchmarkOptions(base + flags) }
        }
    }
}
