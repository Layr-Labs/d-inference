import ArgumentParser
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

    private enum PlanningFailure: Error, Equatable {
        case unexpectedCall
    }

    @Test("runtime-only catalog emits eligibility and empty plans without calling storage planning")
    func runtimeOnlySkipsStoragePlanning() async throws {
        let command = try Models.Catalog.parse(["--json", "--include-runtime-eligibility"])
        let plain = CatalogModel(id: "org/plain", s3Name: "plain", displayName: "Plain", sizeGb: 1)
        let output = try await command.makePlanOutput(
            models: [gatedModel, plain],
            runtimeCapabilities: [],
            storagePlan: { _ in throw PlanningFailure.unexpectedCall }
        )
        #expect(output.models.map(\.id) == [gatedModel.id, plain.id])
        #expect(output.runtimeEligibility[gatedModel.id]?.status == .ineligible)
        #expect(output.runtimeEligibility[plain.id]?.status == .eligible)
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(output)) as? [String: Any])
        let plans = try #require(object["download_plans"] as? [String: Any])
        #expect(plans.isEmpty)
        #expect(Set(object.keys) == ["models", "download_plans", "runtime_eligibility"])
    }

    @Test("explicit download plans still plan every entry, including when both flags are set", arguments: [false, true])
    func explicitPlansPreserved(includeRuntimeEligibility: Bool) async throws {
        var arguments = ["--json", "--include-download-plans"]
        if includeRuntimeEligibility { arguments.append("--include-runtime-eligibility") }
        let command = try Models.Catalog.parse(arguments)
        let plain = CatalogModel(id: "org/plain", s3Name: "plain", displayName: "Plain", sizeGb: 1)
        let plan = try JSONDecoder().decode(ModelDownloadStoragePlan.self, from: Data(
            #"{"remaining_bytes":1024,"reserve_bytes":2147483648,"required_available_bytes":2147484672,"available_bytes":4294967296,"has_sufficient_capacity":true}"#.utf8))
        var plannedIDs: [String] = []
        let output = try await command.makePlanOutput(
            models: [gatedModel, plain],
            runtimeCapabilities: [],
            storagePlan: { model in
                plannedIDs.append(model.id)
                return plan
            }
        )
        #expect(plannedIDs == [gatedModel.id, plain.id])
        #expect(output.downloadPlans == [gatedModel.id: plan, plain.id: plan])
        #expect(output.runtimeEligibility[gatedModel.id]?.status == .ineligible)
        #expect(output.runtimeEligibility[plain.id]?.status == .eligible)
    }

    @Test("explicit plan failures propagate instead of silently dropping admission evidence")
    func explicitPlanFailurePropagates() async throws {
        let command = try Models.Catalog.parse(["--json", "--include-download-plans"])
        await #expect(throws: PlanningFailure.unexpectedCall) {
            _ = try await command.makePlanOutput(
                models: [gatedModel], runtimeCapabilities: [],
                storagePlan: { _ in throw PlanningFailure.unexpectedCall })
        }
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
