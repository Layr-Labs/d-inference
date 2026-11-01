import Foundation
import Testing

@testable import ProviderCore

/// A native-tracked engine refuses logprob capture and token constraints at
/// submit. The bridge refuses them first as a typed client error so the
/// coordinator sees a 400 invalid_request, never an untyped 500 that strikes
/// its inference-error breaker.
@Suite struct NativeOutputControlRefusalTests {
    @Test func onlyNativeTrackedEnginesRefuseLogprobsAndConstraints() {
        #expect(EngineV2Bridge.nativeOutputControlRefusal(
            nativeTracked: false, capturesLogprobs: false, topLogprobs: 5, constrained: true) == nil)
        #expect(EngineV2Bridge.nativeOutputControlRefusal(
            nativeTracked: true, capturesLogprobs: false, topLogprobs: 0, constrained: false) == nil)
        let logprobs = EngineV2Bridge.nativeOutputControlRefusal(
            nativeTracked: true, capturesLogprobs: false, topLogprobs: 1, constrained: false)
        let constrained = EngineV2Bridge.nativeOutputControlRefusal(
            nativeTracked: true, capturesLogprobs: true, topLogprobs: 0, constrained: true)
        for refusal in [logprobs, constrained] {
            #expect(refusal?.hasPrefix(EngineV2Translation.unsupportedOutputControlPrefix) == true)
        }
        #expect(logprobs != constrained)
    }

    /// A native contract that qualifies capture (GLM5-Next) serves logprob
    /// rows; constraints stay refused on every native engine.
    @Test func capturingNativeEnginesServeLogprobsButNotConstraints() {
        #expect(EngineV2Bridge.nativeOutputControlRefusal(
            nativeTracked: true, capturesLogprobs: true, topLogprobs: 20, constrained: false) == nil)
        #expect(EngineV2Bridge.nativeOutputControlRefusal(
            nativeTracked: true, capturesLogprobs: true, topLogprobs: 3, constrained: true) != nil)
    }

    /// `logprobs: true` captures even with `top_logprobs` omitted or 0, so the
    /// refusal keys on the translated sampling value.
    @Test func everyLogprobsRequestTranslatesToACaptureRow() {
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: nil) == 1)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 0) == 1)
        #expect(EngineV2Translation.topLogprobs(logprobs: nil, topLogprobs: 5) == 0)
        #expect(EngineV2Translation.topLogprobs(logprobs: false, topLogprobs: 5) == 0)
    }

    @Test func refusalIsATypedClientErrorOnBothSubmitPaths() throws {
        let message = try #require(EngineV2Bridge.nativeOutputControlRefusal(
            nativeTracked: true, capturesLogprobs: false, topLogprobs: 2, constrained: false))
        // Throwing submit (coordinator relay) and the non-throwing wrapper's
        // in-band `.error` marker classify identically.
        let parsed = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(parsed == .unsupportedOutputControl(message))
        for error in [MultiModelBatchSchedulerEngineError.unsupportedOutputControl(message), parsed] {
            let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .request)
            #expect(failure.code == .invalidRequest)
            #expect(failure.statusCode == 400)
            #expect(failure.errorReason == .clientError)
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        }
        // The untyped submit failure it replaces stays a 500.
        let untyped = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
            "engine_v2 submit failed: unsupported consumer")
        #expect(ProviderLoop.sanitizedInferenceFailure(from: untyped, phase: .request).statusCode == 500)
    }
}
