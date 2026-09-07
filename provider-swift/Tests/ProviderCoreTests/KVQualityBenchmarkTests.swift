import Foundation
import MLXLMCommon
import Testing
@testable import ProviderBenchmark

@Suite("Bounded free-generation input and collection")
struct KVQualityBenchmarkTests {
    private let hash = String(repeating: "a", count: 64)
    private func input(cases: [KVQualityInput.Case], concurrency: Int? = nil) -> KVQualityInput {
        .init(modelID: "catalog-model", expectedModelAggregateSHA256: hash, concurrency: concurrency, cases: cases)
    }
    private var sample: KVQualityInput.Case { .init(name: "arithmetic", promptTokens: [1, 2], maxTokens: 8, expectedText: "2") }

    @Test func inputPinsIdentityVocabularyAndFiniteWork() throws {
        try input(cases: [sample]).validate(modelID: "catalog-model", vocabularySize: 3)
        #expect(input(cases: [sample]).resolvedConcurrency == 1)
        #expect(throws: KVQualityInput.Failure.invalidIdentity) { try input(cases: [sample]).validate(modelID: "other") }
        #expect(throws: KVQualityInput.Failure.invalidTokens) { try input(cases: [sample]).validate(modelID: "catalog-model", vocabularySize: 2) }
        for cases in [[], [sample, sample], (0..<17).map { KVQualityInput.Case(name: "c\($0)", promptTokens: [1], maxTokens: 1, expectedText: nil) }] {
            #expect(throws: KVQualityInput.Failure.invalidCases) { try input(cases: cases).validate(modelID: "catalog-model") }
        }
        for width in [0, 3, 8] {
            #expect(throws: KVQualityInput.Failure.invalidConcurrency) { try input(cases: [sample], concurrency: width).validate(modelID: "catalog-model") }
        }
        for sample in [
            KVQualityInput.Case(name: "empty", promptTokens: [], maxTokens: 1, expectedText: nil),
            .init(name: "long", promptTokens: Array(repeating: 1, count: 32_769), maxTokens: 1, expectedText: nil),
            .init(name: "negative", promptTokens: [-1], maxTokens: 1, expectedText: nil),
            .init(name: "output", promptTokens: [1], maxTokens: 513, expectedText: nil),
        ] {
            #expect(throws: KVQualityInput.Failure.invalidTokens) { try input(cases: [sample]).validate(modelID: "catalog-model") }
        }
    }

    @Test func unknownJSONControlsAreRejected() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let object: [String: Any] = ["modelID": "catalog-model", "expectedModelAggregateSHA256": hash,
            "temperature": 1, "cases": [["name": "c", "promptTokens": [1], "maxTokens": 1]]]
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        #expect(throws: KVQualityInput.Failure.unsupportedFields) { try KVQualityInput.read(path) }
    }

    @Test func earlyEOSPreservesRawTokensAndAuthoritativeText() {
        var collector = KVQualityEventCollector(maximumTokens: 8)
        let acceptedDelta = collector.append(.delta(text: "2", tokens: [42, 99], logprobs: nil))
        let acceptedFinish = collector.append(.finished(reason: .stop, usage: .init(promptTokens: 2, completionTokens: 2)))
        #expect(acceptedDelta && acceptedFinish)
        collector.close(cancelled: false)
        #expect(collector.tokens == [42, 99])
        #expect(collector.streamedText == "2" && collector.finishReason == "stop")
        #expect(collector.issues.isEmpty)
        #expect(KVQualityEventCollector.matches(collector.streamedText, expected: "2").exact == true)
    }

    @Test func expectedMatchesTrimOnlyOuterWhitespaceAndMissingIsUngraded() {
        let ungraded = KVQualityEventCollector.matches("anything", expected: nil)
        #expect(ungraded.exact == nil && ungraded.outerWhitespace == nil)
        let outer = KVQualityEventCollector.matches("\n2 \n", expected: "2")
        #expect(outer.exact == false && outer.outerWhitespace == true)
        #expect(KVQualityEventCollector.matches("a  b", expected: "a b").outerWhitespace == false)
        #expect(KVQualityEventCollector.matches("Answer: 2", expected: "2").outerWhitespace == false)
    }

    @Test func malformedStreamsNeverLookLikeSuccessfulCases() {
        var missing = KVQualityEventCollector(maximumTokens: 1)
        missing.close(cancelled: false)
        #expect(missing.issues == ["missing_terminal"])
        var excessive = KVQualityEventCollector(maximumTokens: 1)
        let acceptedExcess = excessive.append(.delta(text: "ab", tokens: [1, 2], logprobs: nil))
        #expect(!acceptedExcess)
        #expect(excessive.issues == ["output_limit_exceeded"])
        var terminal = KVQualityEventCollector(maximumTokens: 1)
        let acceptedFinish = terminal.append(.finished(reason: .length, usage: .init(promptTokens: 1, completionTokens: 1)))
        let acceptedLate = terminal.append(.delta(text: "late", tokens: [1], logprobs: nil))
        #expect(acceptedFinish && !acceptedLate)
        #expect(terminal.issues == ["delta_after_terminal"])
    }

    @Test func outOfOrderCompletionRetainsCaseIdentity() throws {
        func row(_ index: Int, requestID: UInt64? = nil) -> KVQualityCollectedCase {
            .init(index: index, requestID: requestID ?? UInt64(index + 1), receiptID: UInt64(index + 20),
                elapsedMs: Double(index), firstTokenMs: nil, tokens: [index], streamedText: "case\(index)",
                finishReason: "length", terminalCause: nil, error: nil, issues: [])
        }
        let ordered = try KVQualityEventCollector.ordered([row(2), row(0), row(1)], count: 3)
        #expect(ordered.map(\.index) == [0, 1, 2])
        #expect(ordered.map(\.tokens) == [[0], [1], [2]])
        #expect(throws: KVQualityBenchmark.Failure.self) { try KVQualityEventCollector.ordered([row(0), row(0)], count: 2) }
        #expect(throws: KVQualityBenchmark.Failure.self) { try KVQualityEventCollector.ordered([row(0, requestID: 2)], count: 1) }
    }

    @Test func actualDrainKeepsConcurrentStreamsAndReceiptsSeparate() async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let results = await withTaskGroup(of: KVQualityCollectedCase.self, returning: [KVQualityCollectedCase].self) { group in
            for index in 0..<3 {
                group.addTask {
                    let stream = AsyncStream<CBv2Event> { continuation in
                        Task {
                            if index == 0 { try? await Task.sleep(nanoseconds: 15_000_000) }
                            continuation.yield(.delta(text: "case\(index)", tokens: [index + 10], logprobs: nil))
                            continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: index + 1, completionTokens: 1)))
                            continuation.finish()
                        }
                    }
                    return await KVQualityEventCollector.drain(events: stream, index: index,
                        receiptID: UInt64(index + 90), maximumTokens: 4, startedAt: start,
                        cancel: { Issue.record("valid streams must not cancel") })
                }
            }
            var collected: [KVQualityCollectedCase] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let ordered = try KVQualityEventCollector.ordered(results, count: 3)
        #expect(ordered.map(\.tokens) == [[10], [11], [12]])
        #expect(ordered.map(\.streamedText) == ["case0", "case1", "case2"])
        #expect(ordered.map(\.receiptID) == [90, 91, 92])
        #expect(ordered.allSatisfy { $0.issues.isEmpty && $0.finishReason == "stop" })
    }

    @Test func cancellingADrainPreservesAnExplicitIncompleteOutcome() async {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let task = Task {
            await KVQualityEventCollector.drain(events: stream, index: 0, receiptID: 40,
                maximumTokens: 4, startedAt: DispatchTime.now().uptimeNanoseconds, cancel: {})
        }
        task.cancel()
        let result = await task.value
        continuation.finish()
        #expect(result.issues == ["collection_cancelled_or_timed_out"])
        #expect(result.finishReason == nil)
    }
}
