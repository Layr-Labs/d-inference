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
    func metricsUseMaxFirstTokenMinusMinSubmission() throws {
        let metrics = try ArrivalPrefillAccounting.metrics(
            batchSize: 2,
            promptTokensPerRequest: 2048,
            rows: [
                .init(submissionNs: 2_000_000_000, firstTokenNs: 5_000_000_000),
                .init(submissionNs: 1_000_000_000, firstTokenNs: 5_827_000_000),
            ])
        #expect(abs(metrics.makespanSeconds - 4.827) < 1e-9)
        #expect(
            abs(metrics.aggregateTokensPerSecond - Double(2 * 2047) / 4.827)
                < 1e-9)
    }

    @Test
    func missingOrInvalidRowsPoisonTheCell() {
        #expect(
            throws: ArrivalPrefillAccounting.AccountingError.missingRows(
                expected: 2, actual: 1)
        ) {
            try ArrivalPrefillAccounting.metrics(
                batchSize: 2,
                promptTokensPerRequest: 512,
                rows: [.init(submissionNs: 1, firstTokenNs: 2)])
        }
        #expect(
            throws: ArrivalPrefillAccounting.AccountingError.firstTokenPrecedesSubmission(
                row: 0)
        ) {
            try ArrivalPrefillAccounting.metrics(
                batchSize: 1,
                promptTokensPerRequest: 512,
                rows: [.init(submissionNs: 2, firstTokenNs: 1)])
        }
    }

    @Test
    func aggregateConversionCannotOverflowInt() {
        let tps = ArrivalPrefillAccounting.aggregateTokensPerSecond(
            batchSize: Int.max,
            promptTokensPerRequest: Int.max,
            prefillMakespanSeconds: 1)
        #expect(tps.isFinite)
        #expect(tps > 0)
        #expect(ArrivalPrefillAccounting.prefillTokensPerRow(promptTokensPerRequest: Int.min) == 0)
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

    @Test
    func arrivalRowsEncodeAllThreeTimestamps() throws {
        let data = Data("""
            {
              "row": 0,
              "scheduledDelayMs": 0,
              "submittedAtMs": 1.25,
              "arrivalErrorMs": 1.25,
              "ttftMs": 3.5,
              "firstTokenAtMs": 4.75,
              "decodeTokensPerSecond": 10,
              "generatedTokens": 2,
              "completedAtMs": 8.5,
              "tokenChecksum": "0123456789abcdef"
            }
            """.utf8)
        let row = try JSONDecoder().decode(ArrivalInvarianceBenchmarkReport.Row.self, from: data)
        #expect(row.submittedAtMs == 1.25)
        #expect(row.firstTokenAtMs == 4.75)
        #expect(row.completedAtMs == 8.5)

        let encoded = try JSONEncoder().encode(row)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["submittedAtMs"] != nil)
        #expect(object["firstTokenAtMs"] != nil)
        #expect(object["completedAtMs"] != nil)
    }

    @Test
    func schedulerSampleEncodesCanonicalChecksumAndCompatibilityAlias() throws {
        let data = Data("""
            {
              "strategy": "cbv2",
              "promptTokens": 512,
              "iteration": 1,
              "ttftMs": 100,
              "msPerPrefillToken": 0.2,
              "resolvedKVBackend": "contiguous",
              "tokenChecksum": "aaaaaaaaaaaaaaaa",
              "firstTokenChecksum": "aaaaaaaaaaaaaaaa"
            }
            """.utf8)
        let sample = try JSONDecoder().decode(
            SchedulerPrefillBenchmarkReport.Sample.self, from: data)
        #expect(sample.tokenChecksum == "aaaaaaaaaaaaaaaa")

        let encoded = try JSONEncoder().encode(sample)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["tokenChecksum"] as? String == "aaaaaaaaaaaaaaaa")
        #expect(object["firstTokenChecksum"] as? String == "aaaaaaaaaaaaaaaa")
    }
}
