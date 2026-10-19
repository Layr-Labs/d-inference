import Foundation
import MLXLLM
import ProviderCoreFoundation

/// One verified snapshot plus the context bound every sizing, MTP history and
/// paged backend is built for. Read once per load so a concurrently changed
/// selection or catalog entry cannot mix plan and bound.
struct GLM5NextServingPlan {
    let plan: GLM5NextArtifactPlan
    let maximumContextLength: Int

    /// The default output budget leaves half the bound for the prompt, so a
    /// request that omits `max_tokens` cannot exceed the bound by default.
    /// Longer requests are refused at the bridge's advertised context.
    func boundedSizing(_ sizing: SlotSizingSnapshot) throws -> SlotSizingSnapshot {
        let context = try GLM5NextExecutionBound.require(maximumContextLength,
            modelMaximum: sizing.maxContextLength)
        return .init(weightsBytes: sizing.targetWeightsBytes,
            auxiliaryWeightBytes: sizing.auxiliaryWeightBytes,
            fp16KVBytesPerToken: sizing.fp16KVBytesPerToken, maxContextLength: context,
            defaultMaxTokens: min(sizing.defaultMaxTokens, max(1, context / 2)))
    }
}

/// Coordinator-connected GLM-5.3-Flash. The catalog revision arrives through
/// the ordinary model-revision download; this binds that snapshot to the same
/// managed load as the local opt-in, without a selection file.
enum GLM5NextCoordinatorServing {
    static let catalogModelID = "glm-5.3-flash"
    /// Advertised and enforced prompt + output bound, in tokens.
    static let maximumContextLength = 262_144

    static func isManagedModelID(_ id: String) -> Bool {
        id == catalogModelID || id == GLM5NextLocalQualification.modelID
    }

    /// Identity chain: the coordinator catalog entry pins version and aggregate;
    /// the revision receipt must carry both and its file digests must hash to
    /// that aggregate (`GLM5NextManifestSnapshot`); the admitted load then hashes
    /// every file against the same manifest. The template stays pinned.
    ///
    /// A revision rollback restores a snapshot the catalog no longer names.
    /// `previouslyVerifiedAggregate` is the provider's own live hash for that
    /// snapshot, already verified when it served; a receipt with exactly that
    /// aggregate is pinned by it instead of the catalog version.
    static func resolvePlan(
        modelID: String, directory: URL, catalog: CatalogModel?,
        previouslyVerifiedAggregate: String? = nil
    ) throws -> GLM5NextServingPlan {
        guard modelID == catalogModelID else { throw GLM5NextManagedLoadError.identityMismatch }
        guard let catalog, catalog.id == modelID, catalog.version != nil,
            catalog.aggregateSHA256 != nil
        else {
            throw GLM5NextManagedLoadError.metadata(
                "the coordinator catalog entry for \(modelID) is unavailable")
        }
        guard let manifest = ModelDownloader.revisionReceipt(at: directory),
            manifest.modelID == modelID
        else { throw GLM5NextManagedLoadError.identityMismatch }
        let identity: CatalogModel
        if manifest.version == catalog.version, manifest.aggregateSHA256 == catalog.aggregateSHA256 {
            identity = catalog
        } else if let previouslyVerifiedAggregate,
            previouslyVerifiedAggregate == manifest.aggregateSHA256
        {
            identity = CatalogModel(
                id: modelID, s3Name: manifest.r2Prefix, displayName: catalog.displayName,
                sizeGb: catalog.sizeGb, version: manifest.version, r2Prefix: manifest.r2Prefix,
                aggregateSHA256: manifest.aggregateSHA256, maxContextLength: catalog.maxContextLength)
        } else {
            throw GLM5NextManagedLoadError.identityMismatch
        }
        let context = try servedContextLength(catalogMaximum: catalog.maxContextLength)
        let plan = try GLM5NextArtifactPlan.inspect(directory: directory, catalog: identity, manifest: manifest)
        try GLM5NextLocalQualification.requireShippedTemplate(plan)
        return .init(plan: plan, maximumContextLength: context)
    }

    /// A smaller catalog bound shrinks every bound-priced charge; a larger one
    /// would advertise context the provider refuses, so it fails the load.
    static func servedContextLength(catalogMaximum: Int?) throws -> Int {
        guard let catalogMaximum else { return maximumContextLength }
        guard catalogMaximum > 0, catalogMaximum <= maximumContextLength else {
            throw GLM5NextManagedLoadError.metadata(
                "catalog max_context_length \(catalogMaximum) exceeds the enforced "
                    + "\(maximumContextLength)-token GLM bound")
        }
        return catalogMaximum
    }

    /// Target DSA storage per token: every sparse layer keeps one FP32 row of
    /// the kv_lora_rank latent (no rotary part) plus index keys, pool gates and
    /// a validity column. KDA layers carry fixed recurrent state instead; the
    /// embedded MTP layer is charged per reserved token by the engine.
    static func targetKVBytesPerToken(_ text: GLM5NextTextConfiguration) -> Int {
        let sparse = text.layerTypes.filter { $0 == .deepseekSparseAttention }.count
        return sparse * (text.kvLoraRank + 2 * text.indexHeadDim + 1) * 4
    }

    /// Target bytes per reserved token the bridge charges and reports as
    /// `kv_bytes_per_token` beside the MTP rate: target KV plus the native
    /// step-scratch price per context token (`PagedKVBackend.glm5NextStepScratch`).
    static func requestBytesPerToken(kvBytesPerToken: Int, stepScratchBytesPerToken: Int) -> Int? {
        let (sum, overflow) = kvBytesPerToken.addingReportingOverflow(stepScratchBytesPerToken)
        return overflow || kvBytesPerToken < 0 || stepScratchBytesPerToken < 0 ? nil : sum
    }

    /// The advertised bound must be serveable alone, or the coordinator would
    /// route requests this slot can never admit. `admissibleBytes` is the
    /// slot's request capacity after the admission watermark and one step's setup.
    static func fullContextRefusal(
        admissibleBytes: Int, fixedRequestBytes: Int, bytesPerToken: Int, context: Int
    ) -> String? {
        let (variable, variableOverflow) = bytesPerToken.multipliedReportingOverflow(by: context)
        let (needed, neededOverflow) = variable.addingReportingOverflow(fixedRequestBytes)
        guard variableOverflow || neededOverflow || fixedRequestBytes < 0 || bytesPerToken <= 0
            || needed > admissibleBytes
        else { return nil }
        return "GLM admissible capacity of \(admissibleBytes) bytes after one step's setup cannot "
            + "hold one \(context)-token request (fixed \(fixedRequestBytes) bytes + "
            + "\(bytesPerToken) bytes/token)"
    }

    static func describe(_ error: any Error) -> String {
        switch error as? GLM5NextManagedLoadError {
        case .metadata(let reason)?: return reason
        case .identityMismatch?:
            return "the installed revision does not match the coordinator catalog identity"
        case .invalidManifest?: return "the installed revision manifest is invalid"
        case .changed(let name)?: return "the installed revision changed (\(name))"
        case .admission?: return "the GLM LOAD quotation is stale or not admitted"
        case .nativeMTPRequired?:
            return "GLM serves only with its embedded MTP; leave mtp_mode and DARKBLOOM_CBV2_MTP enabled"
        default: return String(describing: error)
        }
    }
}
