import Foundation
import Testing
@testable import ProviderCore

private struct SecretInferenceError: Error, LocalizedError, CustomStringConvertible {
    static let sentinel = "PROMPT_SECRET https://private.invalid/path?token=raw"
    var errorDescription: String? { Self.sentinel }
    var description: String { Self.sentinel }
}

@Test func sanitizedInferenceFailureDropsRichErrorTextFromWireAndLogs() throws {
    let failure = ProviderLoop.sanitizedInferenceFailure(
        from: SecretInferenceError(),
        phase: .generation)
    let message = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "request-id",
        failure: failure))
    let wire = try ProviderProtocolCodec.encodeProviderMessage(message)
    let wireText = try #require(String(data: wire, encoding: .utf8))

    final class Lines: @unchecked Sendable {
        let lock = NSLock()
        var values: [String] = []
    }
    let lines = Lines()
    InferenceFailureLogger { line in
        lines.lock.withLock { lines.values.append(line) }
    }.record(requestId: "request-id", failure: failure)
    let logText = lines.lock.withLock { lines.values.joined(separator: "\n") }

    #expect(failure.code == .generationFailure)
    #expect(!wireText.contains(SecretInferenceError.sentinel))
    #expect(!logText.contains(SecretInferenceError.sentinel))
    #expect(wireText.contains(#""failure_code":"generation_failure""#))
}

@Test func boundedCapacityReasonsPreserveRoutingWithoutLeakingNumbers() {
    let secret = "request requires 424242 tokens but only 17 available PROMPT_SECRET"
    let failure = ProviderLoop.sanitizedInferenceFailure(
        from: MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(secret),
        phase: .streamStart)

    #expect(failure.code == .capacity)
    #expect(failure.errorReason == .requestExceedsNodeBudget)
    #expect(!failure.message.contains("424242"))
    #expect(!failure.message.contains("PROMPT_SECRET"))
}

/// D6: a request a pair aborted mid-stream for one Mac's memory reaches the
/// coordinator as the pair's capacity refusal does, retryable, with no
/// numbers or rank in its wire text.
@Test func aPairsMemoryAbortIsTheCoordinatorsCapacityRefusal() throws {
    let message = DistributedMemoryAbort.message(requestedContextTokens: 131_072, servingContextTokens: 65_536, rank: 1)
    #expect(DistributedMemoryAbort.matches(message))
    #expect(!DistributedMemoryAbort.matches("token_budget_exhausted: KV capacity exhausted after requeues"))
    let failure = ProviderLoop.sanitizedInferenceFailure(
        from: MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message), phase: .generation)
    #expect(failure.code == .capacity)
    #expect(failure.errorReason == .requestExceedsNodeBudget)
    #expect(failure.statusCode == 503)
    let wire = try ProviderProtocolCodec.encodeProviderMessage(.inferenceError(.init(requestId: "request-id", failure: failure)))
    let text = try #require(String(data: wire, encoding: .utf8))
    #expect(!text.contains("131072") && !text.contains("refused it while it ran"))
}

@Test func typedMediaFailuresPreserveSpecificClosedCodesOnWire() throws {
    let cases: [(error: any Error, code: InferenceFailureCode, message: String)] = [
        (
            MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel(
                "PROVIDER_MEDIA_DETAIL_LEAK_SENTINEL"),
            .unsupportedMedia,
            "Media input is not supported."
        ),
        (
            MultiModelBatchSchedulerEngineError.multimodalRejected(
                "CALLER_MEDIA_DETAIL_LEAK_SENTINEL"),
            .invalidMedia,
            "Invalid media input."
        ),
    ]

    for testCase in cases {
        let failure = ProviderLoop.sanitizedInferenceFailure(
            from: testCase.error,
            phase: .streamStart)
        let message = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
            requestId: "request-id",
            failure: failure))
        let wire = try ProviderProtocolCodec.encodeProviderMessage(message)
        let wireText = try #require(String(data: wire, encoding: .utf8))

        #expect(failure.code == testCase.code)
        #expect(failure.statusCode == 400)
        #expect(failure.errorReason == .clientError)
        #expect(failure.message == testCase.message)
        #expect(wireText.contains(#""failure_code":"\#(testCase.code.rawValue)""#))
        #expect(!wireText.contains("MEDIA_DETAIL_LEAK_SENTINEL"))
    }
}

@Test func malformedCallerMediaKeepsClosedInvalidMediaClassification() {
    let failure = ProviderLoop.sanitizedInferenceFailure(
        from: MediaIngest.MediaError.malformedDataURI(
            "CALLER_MEDIA_DETAIL_LEAK_SENTINEL"),
        phase: .streamStart,
        errorReason: .clientError)

    #expect(failure.code == .invalidMedia)
    #expect(failure.statusCode == 400)
    #expect(failure.errorReason == .clientError)
    #expect(failure.message == "Invalid media input.")
    #expect(!failure.message.contains("MEDIA_DETAIL_LEAK_SENTINEL"))
}
