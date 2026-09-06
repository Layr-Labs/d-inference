import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("catalog runtime eligibility output")
struct ModelsCatalogOutputTests {
    private var gatedModel: CatalogModel {
        CatalogModel(
            id: ModelRuntimeRequirements.qwen38ConcreteModelID,
            s3Name: "gated", displayName: "Gated model", sizeGb: 10, minRamGb: 16)
    }

    @Test("RAM does not bypass embedded M5/NAX requirements missing from catalog metadata")
    func embeddedRuntimeGateIsReported() {
        let verdict = ModelsCatalogRuntimeEligibility(model: gatedModel, available: [])
        #expect(verdict.status == .ineligible)
        #expect(verdict.reason.contains("Apple M5"))
        #expect(verdict.reason.contains("NAX runtime"))
        let eligible = ModelsCatalogRuntimeEligibility(
            model: gatedModel, available: ModelRuntimeRequirements.qwen38RequiredCapabilities)
        #expect(eligible.status == .eligible)
    }

    @Test("unavailable detection is unknown for gated models and eligible for ungated models")
    func unavailableDetectionStaysUnknown() {
        #expect(ModelsCatalogRuntimeEligibility(model: gatedModel, available: nil).status == .unknown)
        let ungated = CatalogModel(id: "org/plain", s3Name: "plain", displayName: "Plain", sizeGb: 1)
        #expect(ModelsCatalogRuntimeEligibility(model: ungated, available: nil).status == .eligible)
    }

    @Test("catalog-supplied and future capabilities use the same canonical evaluator")
    func catalogRequirementsAreNotDropped() {
        let requirement = ProviderRuntimeCapability(rawValue: "future_runtime")
        let model = CatalogModel(
            id: "org/other", s3Name: "other", displayName: "Other", sizeGb: 1,
            requiredProviderCapabilities: [requirement])
        let refused = ModelsCatalogRuntimeEligibility(model: model, available: [])
        #expect(refused.status == .ineligible)
        #expect(refused.reason.contains("future_runtime"))
        #expect(ModelsCatalogRuntimeEligibility(model: model, available: [requirement]).status == .eligible)
    }

    @Test("runtime eligibility is additive to the plan envelope; ordinary catalog data remains an array")
    func envelopeWireShape() throws {
        let output = ModelsCatalogPlanOutput(
            models: [gatedModel], downloadPlans: [:], runtimeCapabilities: [])
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(output)) as? [String: Any])
        #expect(Set(object.keys) == ["models", "download_plans", "runtime_eligibility"])
        let verdicts = try #require(object["runtime_eligibility"] as? [String: [String: String]])
        #expect(verdicts[gatedModel.id]?["status"] == "ineligible")
        #expect(verdicts[gatedModel.id]?["reason"]?.contains("Apple M5") == true)
        let array = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(output.models)) as? [[String: Any]])
        #expect(array.first?["id"] as? String == gatedModel.id)
        #expect(array.first?["runtime_eligibility"] == nil)
    }
}
