import Foundation
import Testing
@testable import ProviderCore

private let promptWorkIdentity = PromptWorkIdentity(
    modelArtifactHash: String(repeating: "a", count: 64),
    promptContractID: String(repeating: "b", count: 64))

@Test func promptWorkRequiresExactArtifactTemplateAndActualTokenization() throws {
    let work = PromptWork(source: "exact_contract", promptTokens: 8_828,
        upperBoundTokens: 8_828, promptContractID: promptWorkIdentity.promptContractID,
        modelArtifactHash: promptWorkIdentity.modelArtifactHash)
    #expect(work.reconciled(actualPromptTokens: 8_828, identity: promptWorkIdentity) != nil)
    #expect(work.reconciled(actualPromptTokens: 8_829, identity: promptWorkIdentity) == nil)
    #expect(work.reconciled(actualPromptTokens: 8_827, identity: promptWorkIdentity) == nil)
    #expect(work.reconciled(actualPromptTokens: 8_828, identity: nil) == nil)
    #expect(work.reconciled(actualPromptTokens: 8_828, identity: .init(
        modelArtifactHash: String(repeating: "c", count: 64),
        promptContractID: promptWorkIdentity.promptContractID)) == nil)
    var calibrated = work
    calibrated.source = "calibrated_template"
    calibrated.calibrationID = "reviewed-corpus-v1"
    calibrated.upperBoundTokens = 10_000
    #expect(calibrated.reconciled(actualPromptTokens: 9_999, identity: promptWorkIdentity) != nil)
    #expect(calibrated.reconciled(actualPromptTokens: 10_001, identity: promptWorkIdentity) == nil)
    calibrated.version = 2
    #expect(calibrated.reconciled(actualPromptTokens: 9_999, identity: promptWorkIdentity) == nil)
}

@Test func promptWorkWireIsOptionalAndKeepsUnknownEvidenceUnqualified() throws {
    let work = PromptWork(source: "exact_contract", promptTokens: 4_096,
        upperBoundTokens: 4_096, promptContractID: promptWorkIdentity.promptContractID,
        modelArtifactHash: promptWorkIdentity.modelArtifactHash)
    let frame = CoordinatorMessage.inferenceRequest(.init(
        requestId: "synthetic", firstContentBudgetMs: 500, promptWork: work))
    let encoded = try JSONEncoder().encode(frame)
    #expect(try JSONDecoder().decode(CoordinatorMessage.self, from: encoded) == frame)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let wire = try #require(object["prompt_work"] as? [String: Any])
    #expect(wire["prompt_tokens"] as? Int == 4_096)
    #expect(wire["upper_bound_tokens"] as? Int == 4_096)
    let old = try JSONDecoder().decode(CoordinatorMessage.self,
        from: Data(#"{"type":"inference_request","request_id":"old"}"#.utf8))
    guard case .inferenceRequest(let request) = old else { Issue.record("wrong frame"); return }
    #expect(request.promptWork == nil)
    let unknown = PromptWork(source: "heuristic", promptTokens: 4_096, upperBoundTokens: 0)
    #expect(unknown.reconciled(actualPromptTokens: 4_096, identity: promptWorkIdentity) == nil)
}

@Test func malformedAdvisoryPromptWorkKeepsTheInferenceFrame() throws {
    for malformed in [
        "null", "true", "42", #""unexpected""#, "[]", "{}",
        #"{"version":1,"source":"exact_contract","prompt_tokens":"4096","upper_bound_tokens":4096}"#,
        #"{"version":1,"source":"exact_contract","prompt_tokens":4096.5,"upper_bound_tokens":4096}"#,
        #"{"version":1,"source":"exact_contract","prompt_tokens":4096,"upper_bound_tokens":1e100}"#,
    ] {
        let data = Data("""
            {"type":"inference_request","request_id":"preserved", \
             "first_content_budget_ms":500,"cache_scope":"scope","prompt_work":\(malformed)}
            """.utf8)
        let decoded = try JSONDecoder().decode(CoordinatorMessage.self, from: data)
        guard case .inferenceRequest(let request) = decoded else { Issue.record("wrong frame"); continue }
        #expect(request.requestId == "preserved")
        #expect(request.firstContentBudgetMs == 500 && request.cacheScope == "scope")
        #expect(request.promptWork == nil)
    }
    // Required identity and the original deadline retain their strict codec;
    // tolerating an advisory field cannot make a malformed request executable.
    for frame in [
        #"{"type":"inference_request","prompt_work":{}}"#,
        #"{"type":"inference_request","request_id":42,"prompt_work":{}}"#,
        #"{"type":"inference_request","request_id":"bad","first_content_budget_ms":"500","prompt_work":{}}"#,
    ] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CoordinatorMessage.self, from: Data(frame.utf8))
        }
    }
}
