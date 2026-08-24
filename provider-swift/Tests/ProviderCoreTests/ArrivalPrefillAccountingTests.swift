import Foundation
import ProviderBenchmark
import Testing

@Suite
struct ArrivalPrefillAccountingTests {
    @Test
    func allowedBatchSizesAreExactlyOneTwoFour() {
        #expect(ArrivalPrefillAccounting.allowedBatchSizes == [1, 2, 4])
        #expect(ArrivalPrefillAccounting.patternNames(batchSize: 3).isEmpty)
        #expect(ArrivalPrefillAccounting.delaysMs(batchSize: 3, pattern: "burst") == nil)
    }

    @Test
    func batchSizeSelectsRowCount() {
        #expect(ArrivalPrefillAccounting.delaysMs(batchSize: 1, pattern: "burst") == [0])
        #expect(ArrivalPrefillAccounting.delaysMs(batchSize: 2, pattern: "burst") == [0, 0])
        #expect(
            ArrivalPrefillAccounting.delaysMs(batchSize: 4, pattern: "burst")
                == [0, 0, 0, 0])
        #expect(ArrivalPrefillAccounting.delaysMs(batchSize: 2, pattern: "stagger-25ms") == [0, 25])
        #expect(
            ArrivalPrefillAccounting.delaysMs(batchSize: 4, pattern: "stagger-25ms")
                == [0, 25, 50, 75])
    }

    @Test
    func everyNamedPatternHasExactlyBatchSizeRows() {
        for batch in ArrivalPrefillAccounting.allowedBatchSizes {
            for name in ArrivalPrefillAccounting.patternNames(batchSize: batch) {
                let delays = ArrivalPrefillAccounting.delaysMs(batchSize: batch, pattern: name)
                #expect(delays?.count == batch, "\(name) B=\(batch)")
            }
        }
    }

    @Test
    func aggregateUsesLMinusOneAndPrefillMakespan() {
        // 4 × 2048-token prompts, 4827 ms first-token makespan.
        let tps = ArrivalPrefillAccounting.aggregateTokensPerSecond(
            batchSize: 4,
            promptTokensPerRequest: 2048,
            prefillMakespanSeconds: 4.827)
        let expected = Double(4 * 2047) / 4.827
        #expect(abs(tps - expected) < 1e-9)
        #expect(ArrivalPrefillAccounting.prefillTokensPerRow(promptTokensPerRequest: 2048) == 2047)
        #expect(ArrivalPrefillAccounting.prefillTokensPerRow(promptTokensPerRequest: 1) == 0)
        #expect(
            ArrivalPrefillAccounting.aggregateTokensPerSecond(
                batchSize: 4,
                promptTokensPerRequest: 2048,
                prefillMakespanSeconds: 0) == 0)
    }

    @Test
    func makespanIsMaxFirstMinusMinSubmit() {
        let seconds = ArrivalPrefillAccounting.prefillMakespanSeconds(
            minSubmissionNs: 1_000_000_000,
            maxFirstTokenNs: 5_827_000_000)
        #expect(abs(seconds - 4.827) < 1e-9)
        #expect(
            ArrivalPrefillAccounting.prefillMakespanSeconds(
                minSubmissionNs: 10,
                maxFirstTokenNs: 10) == 0)
    }

    @Test
    func tokenChecksumIsStableAndOrderSensitive() {
        #expect(
            ArrivalPrefillAccounting.tokenChecksum([1, 2, 3])
                == ArrivalPrefillAccounting.tokenChecksum([1, 2, 3]))
        #expect(
            ArrivalPrefillAccounting.tokenChecksum([1, 2, 3])
                != ArrivalPrefillAccounting.tokenChecksum([3, 2, 1]))
        #expect(ArrivalPrefillAccounting.tokenChecksum([]) == "cbf29ce484222325")
    }
}
