import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// E5: forced tool_choice enforcement failures ("model did not emit the
/// required tool call" / "outside tool_choice" / "deferred content limit")
/// were thrown as `.generationFailed` → generic 500 `cbv2_engine_error`,
/// reading as a provider fault for an OUTPUT-dependent condition a re-sample
/// can fix. They are now the typed `.toolChoiceViolation` → HTTP 422 with
/// wire error_reason "tool_noncompliance" (whitelisted coordinator-side).
@Suite("Tool-choice violation typed error (E5)")
struct ToolChoiceViolationErrorTests {

    private let violations = [
        "model did not emit the required tool call",
        "model emitted a tool call outside tool_choice",
        "required tool call response exceeded deferred content limit",
    ]

    @Test func mapsTo422() {
        for message in violations {
            let status = ProviderLoop.mapInferenceErrorToStatus(
                MultiModelBatchSchedulerEngineError.toolChoiceViolation(message))
            #expect(status == 422, "\(message)")
        }
        #expect(
            ProviderLoop.mapInferenceErrorToStatus(
                MLXOpenAIServiceError.multipleToolCallsNotAllowed) == 422)
    }

    @Test func classifiesAsToolNoncompliance() {
        for message in violations {
            let error = MultiModelBatchSchedulerEngineError.toolChoiceViolation(message)
            #expect(classifyTypedInferenceErrorReason(error) == "tool_noncompliance")
            // The full classifier routes through the typed check first.
            #expect(classifyInferenceErrorReason(error) == "tool_noncompliance")
        }
    }

    @Test func errorDescriptionCarriesTheMessage() {
        let error = MultiModelBatchSchedulerEngineError.toolChoiceViolation(
            "model did not emit the required tool call")
        #expect(error.errorDescription == "model did not emit the required tool call")
    }

    /// The typed classifier is TYPE-driven: other engine errors (including a
    /// generationFailed whose text mentions the same phrases) yield nil, so
    /// the mid-stream terminal cannot mislabel an engine fault.
    @Test func typedClassifierIgnoresOtherErrors() {
        #expect(
            classifyTypedInferenceErrorReason(
                MultiModelBatchSchedulerEngineError.generationFailed(
                    "model did not emit the required tool call")) == nil)
        #expect(
            classifyTypedInferenceErrorReason(
                MultiModelBatchSchedulerEngineError.invalidToolPayload("bad")) == nil)
        #expect(classifyTypedInferenceErrorReason(CancellationError()) == nil)
    }

    /// Regression: the jinja string classification is unchanged by the typed
    /// fast path.
    @Test func jinjaClassificationUnchanged() {
        struct FakeTemplateError: Error, CustomStringConvertible {
            let description = "Jinja.TemplateException: upper filter requires string"
        }
        #expect(classifyInferenceErrorReason(FakeTemplateError()) == "jinja_template")
    }

    /// A generationFailed still maps to 500 — the typed case is what moved.
    @Test func generationFailedStill500() {
        let status = ProviderLoop.mapInferenceErrorToStatus(
            MultiModelBatchSchedulerEngineError.generationFailed("boom"))
        #expect(status == 500)
    }
}
