import Foundation
import MLXLMCommon
import Testing
@testable import ProviderBenchmark

@Suite("Quantized prefill receipts report actual decisions")
struct BenchmarkQuantizedPrefillReceiptTests {
    private func statistics(mode: PagedQuantizedPrefillMode = .opportunisticSDPA,
                            fused: Int = 0, current: Int = 0) throws -> PagedQuantizedPrefillStatistics {
        let json: [String: Any] = ["mode": mode.rawValue,
            "directCallCount": 10, "fusedCallCount": fused,
            "directQueryTokenCount": 2048, "fusedQueryTokenCount": fused * 2048,
            "budgetFallbackCount": 3, "ineligibleFallbackCount": 7,
            "currentAdditionalWorkspaceBytes": current, "peakAdditionalWorkspaceBytes": 65536]
        return try JSONDecoder().decode(PagedQuantizedPrefillStatistics.self,
            from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func opportunisticSelectionWithNoFusedCallsRemainsAnExplicitFallbackReceipt() throws {
        let receipt = try BenchmarkQuantizedPrefillReceipt.make(statistics: statistics(),
            expectedMode: .opportunisticSDPA, successfulTerminalControls: true)
        #expect(receipt.counterScope == "graph_built_layer_rows")
        #expect(receipt.observationScope == "measured_engine_after_shutdown")
        #expect(receipt.statistics.fusedCallCount == 0 && receipt.statistics.directCallCount == 10)
        #expect(receipt.statistics.budgetFallbackCount == 3 && receipt.statistics.ineligibleFallbackCount == 7)
        let encoded = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(BenchmarkQuantizedPrefillReceipt.self, from: encoded)
        #expect(decoded.statistics.fusedQueryTokenCount == 0)
        #expect(decoded.statistics.peakAdditionalWorkspaceBytes == 65536)
    }

    @Test func actualModeAndSuccessfulRetirementAreChecked() throws {
        #expect(throws: BenchmarkQuantizedPrefillReceipt.Failure.self) {
            try BenchmarkQuantizedPrefillReceipt.make(statistics: statistics(mode: .direct),
                expectedMode: .opportunisticSDPA, successfulTerminalControls: true)
        }
        #expect(throws: BenchmarkQuantizedPrefillReceipt.Failure.self) {
            try BenchmarkQuantizedPrefillReceipt.make(statistics: statistics(fused: 1, current: 4096),
                expectedMode: .opportunisticSDPA, successfulTerminalControls: true)
        }
        let failed = try BenchmarkQuantizedPrefillReceipt.make(statistics: statistics(fused: 1, current: 4096),
            expectedMode: .opportunisticSDPA, successfulTerminalControls: false)
        #expect(!failed.successfulTerminalControls && failed.statistics.currentAdditionalWorkspaceBytes == 4096)
    }

    @Test func programmaticNativeSelectionCannotSilentlyIgnoreOpportunisticMode() throws {
        try BenchmarkQuantizedPrefillReceipt.validateSelection(quantization: .native, mode: .direct)
        #expect(throws: BenchmarkQuantizedPrefillReceipt.Failure.self) {
            try BenchmarkQuantizedPrefillReceipt.validateSelection(quantization: .native, mode: .opportunisticSDPA)
        }
    }
}
