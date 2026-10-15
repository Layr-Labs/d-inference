import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

/// The ordinary catalog/download trust boundary remains authoritative. This
/// resolver fetches metadata only; it never downloads or hashes model payloads.
enum GLM5NextLoadFunnel {
    static func resolvePlan(modelID: String, directory: URL, coordinatorURL: String) async throws
        -> GLM5NextArtifactPlan
    {
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL)
        let catalog = try await client.fetchCatalog()
        try Task.checkCancellation()
        guard let selected = catalog.first(where: { $0.id == modelID }) else {
            throw GLM5NextManagedLoadError.invalidManifest
        }
        let manifest = try await client.fetchManifest(modelID: modelID)
        try Task.checkCancellation()
        return try GLM5NextArtifactPlan.inspect(
            directory: directory, catalog: selected, manifest: manifest)
    }

    static func preparation(plan: GLM5NextArtifactPlan, mode: MTPMode, externalPath: String?) throws
        -> SpecDecPreparation
    {
        guard externalPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw GLM5NextManagedLoadError.metadata(
                "GLM uses its embedded predictor; external drafter is unsupported")
        }
        let enabled = mode.enablesMTP(
            forModelType: "glm5_next", embeddedArtifactDeclared: true,
            modelID: plan.weights.catalog.id)
        guard enabled else {
            return .init(artifact: nil, status: .disabled(.configDisabled, configured: false))
        }
        return .init(
            artifact: nil,
            status: .init(
                configured: true, active: false, reason: nil, source: .inline,
                revision: plan.nativeIdentity.revision,
                sourceRevision: plan.nativeIdentity.revision,
                artifactBytes: plan.quotation.mtpBytes, assistantBytes: 0))
    }

    /// Never replace the ordinary scanner allowance with a smaller native one.
    static func estimatedWeightsGb(scanned: Double, plan: GLM5NextArtifactPlan?) -> Double {
        guard let plan else { return scanned }
        guard scanned.isFinite, scanned > 0 else { return plan.quotation.estimatedWeightsGb }
        return max(scanned, plan.quotation.estimatedWeightsGb)
    }

    static func pendingBytes(scanned: Double, plan: GLM5NextArtifactPlan?, extra: UInt64) -> UInt64
    {
        let generic = ProviderLoop.pendingLoadReservationBytes(
            estimatedWeightsGb: estimatedWeightsGb(scanned: scanned, plan: plan),
            extraWeightBytes: extra)
        guard let plan else { return generic }
        let sum = plan.quotation.requiredWeightBytes.addingReportingOverflow(extra)
        return max(generic, sum.overflow ? .max : sum.partialValue)
    }

    /// The root shares its embedding/head with MTP. Count owned array objects
    /// once; retaining that trained partition is not an external assistant load.
    static func sizing(container: ModelContainer, defaultMaxTokens: Int) async throws
        -> SlotSizingSnapshot
    {
        try await container.perform { context in
            guard let root = context.model as? GLM5NextModel else {
                throw GLM5NextManagedLoadError.identityMismatch
            }
            var seen = Set<ObjectIdentifier>()
            var bytes = 0
            for (_, array) in root.parameters().flattened()
            where seen.insert(ObjectIdentifier(array)).inserted {
                let sum = bytes.addingReportingOverflow(array.nbytes)
                guard !sum.overflow else { throw GLM5NextManagedLoadError.admission }
                bytes = sum.partialValue
            }
            return .init(
                weightsBytes: bytes,
                fp16KVBytesPerToken: SlotSizingSnapshot.fp16KVBytesPerToken(
                    layerKinds: root.textTower.cbv2LayerKinds),
                maxContextLength: root.configuration.textConfig.maxPositionEmbeddings,
                defaultMaxTokens: min(
                    defaultMaxTokens, root.configuration.textConfig.maxPositionEmbeddings))
        }
    }

    static func isUnproven(_ error: any Error) -> Bool {
        if error as? GLM5NextManagedLoadError == .retirementUnproven { return true }
        if case .retainedFault? = error as? NativeConstructionError { return true }
        return GLM5NextLoadFaultState.isRetained
    }
}

/// Retains actual failed owners and their activity leases. No timeout, flag or
/// disappearance of a caller can authorize a memory refund after a failed join.
enum GLM5NextLoadFaultState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var owners: [AnyObject] = []
    static var isRetained: Bool { lock.withLock { !owners.isEmpty } }
    static func requireHealthy() throws {
        guard !isRetained else { throw GLM5NextManagedLoadError.retirementUnproven }
    }
    static func retain(_ values: [AnyObject]) {
        lock.withLock {
            for value in values where !owners.contains(where: { $0 === value }) {
                owners.append(value)
            }
        }
    }
}
