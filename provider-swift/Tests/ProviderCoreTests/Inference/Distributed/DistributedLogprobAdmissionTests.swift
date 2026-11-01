import DarkbloomClusterProtocol
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Fabricated owners only; these checks exercise admission and error mapping,
/// never a model, GPU, peer process or native logprob calculation.
@Suite struct DistributedLogprobAdmissionTests {
    @Test func unsupportedCaptureRefusesBeforeReservationAndKeepsOwnerAvailable() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        for count in [1, ClusterWorkerSampling.maximumTopLogprobs] {
            var request = distributedTestRequest()
            request.sampling.topLogprobs = count
            #expect(throws: DistributedEngineError.refused(.logprobCaptureUnsupported)) {
                try engine.submit(request)
            }
        }
        #expect(owner.reserveCount == 0)
        #expect(owner.shutdownCount == 0)
        #expect(engine.capacity().activeRequests == 0)

        // A feature refusal is local to that request: plain text can still run.
        let stream = try engine.submit(distributedTestRequest(maxTokens: 1))
        #expect(owner.reserveCount == 1)
        owner.last.send(.token(4))
        owner.last.acknowledge()
        #expect(distributedText(await distributedCollect(stream)) == "t4")
        await engine.shutdown()
    }

    @Test func numericLogprobLimitsRemainIndependentOfCaptureCapability() throws {
        for captures in [false, true] {
            let profile = try distributedTestProfile(supportsLogprobs: captures)
            var request = distributedTestRequest()
            #expect(profile.refusal(for: request) == nil)
            for count in [-1, ClusterWorkerSampling.maximumTopLogprobs + 1] {
                request.sampling.topLogprobs = count
                #expect(profile.refusal(for: request) == .logprobsUnsupported)
            }
            for count in [1, ClusterWorkerSampling.maximumTopLogprobs] {
                request.sampling.topLogprobs = count
                #expect(profile.refusal(for: request) == (captures ? nil : .logprobCaptureUnsupported))
            }
        }
    }

    @Test func unsupportedCaptureIsAClientErrorWithAnAccurateReason() throws {
        let profile = try distributedTestProfile()
        let message = EngineV2Translation.admissionErrorMessage(
            for: DistributedEngineError.refused(.logprobCaptureUnsupported), distributedProfile: profile)
        let error = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        guard case .distributedRequestRefused(let reason, let detail) = error else {
            Issue.record("Capture refusal lost its deterministic request classification")
            return
        }
        #expect(reason == .logprobCaptureUnsupported)
        #expect(detail.contains("selected cluster mode"))
        #expect(!detail.contains("limit"))
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation)
        #expect(failure.code == .invalidRequest)
        #expect(failure.errorReason == .clientError)
    }
}
