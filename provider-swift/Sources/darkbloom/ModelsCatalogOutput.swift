import Foundation
import ProviderCore

extension Models.Catalog {
    /// Runtime-only browsing must never inspect or hash staged model weights.
    /// Keep the planner lazy; only the explicit download-plan flag invokes it.
    func makePlanOutput(
        models: [CatalogModel],
        runtimeCapabilities: Set<ProviderRuntimeCapability>?,
        storagePlan: (CatalogModel) async throws -> ModelDownloadStoragePlan
    ) async throws -> ModelsCatalogPlanOutput {
        var plans: [String: ModelDownloadStoragePlan] = [:]
        if includeDownloadPlans {
            for model in models {
                plans[model.id] = try await storagePlan(model)
            }
        }
        return ModelsCatalogPlanOutput(
            models: models,
            downloadPlans: plans,
            runtimeCapabilities: runtimeCapabilities
        )
    }
}

/// Additive app envelope. Plain `models catalog --json` remains the catalog array.
/// Runtime-only snapshots include an empty `download_plans` object.
struct ModelsCatalogPlanOutput: Encodable {
    let models: [CatalogModel]
    let downloadPlans: [String: ModelDownloadStoragePlan]
    let runtimeEligibility: [String: ModelsCatalogRuntimeEligibility]

    init(
        models: [CatalogModel],
        downloadPlans: [String: ModelDownloadStoragePlan],
        runtimeCapabilities: Set<ProviderRuntimeCapability>?
    ) {
        self.models = models
        self.downloadPlans = downloadPlans
        runtimeEligibility = Dictionary(models.map { model in
            (model.id, ModelsCatalogRuntimeEligibility(
                model: model, available: runtimeCapabilities))
        }, uniquingKeysWith: { first, _ in first })
    }

    enum CodingKeys: String, CodingKey {
        case models
        case downloadPlans = "download_plans"
        case runtimeEligibility = "runtime_eligibility"
    }
}

/// Presentation of the canonical runtime policy; requirements are never inferred
/// from RAM, model names, or a second app-side requirements table.
struct ModelsCatalogRuntimeEligibility: Encodable, Equatable {
    enum Status: String, Encodable {
        case eligible
        case ineligible
        case unknown
    }

    let status: Status
    let reason: String

    init(model: CatalogModel, available: Set<ProviderRuntimeCapability>?) {
        let eligibility = ModelRuntimeRequirements.evaluate(
            modelID: model.id,
            catalogRequirements: model.requiredProviderCapabilities,
            available: available ?? [])
        guard !eligibility.required.isEmpty else {
            status = .eligible
            reason = "No additional runtime capabilities are required."
            return
        }
        let requirements = ProviderCapabilityLabels.labels(eligibility.required).joined(separator: ", ")
        guard available != nil else {
            status = .unknown
            reason = "Requires \(requirements). Darkbloom could not verify this Mac's runtime capabilities. Run the system check and refresh the catalog."
            return
        }
        if eligibility.isEligible {
            status = .eligible
            reason = "This Mac provides the required runtime capabilities: \(requirements)."
        } else {
            status = .ineligible
            let missing = ProviderCapabilityLabels.labels(eligibility.missing).joined(separator: ", ")
            reason = "Requires \(requirements). Unavailable on this Mac: \(missing)."
        }
    }
}
