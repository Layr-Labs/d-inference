import Foundation

/// Stable, content-free reasons for MTP not being active. These values are
/// written to provider logs and are intentionally safe to aggregate.
public enum MTPFallbackReason: String, Sendable, Equatable {
    case configDisabled = "config_disabled"
    case killSwitchDisabled = "kill_switch_disabled"
    case targetUnsupported = "target_unsupported"
    case localArtifactInvalid = "local_artifact_invalid"
    case catalogDisabled = "catalog_disabled"
    case catalogUnavailable = "catalog_unavailable"
    case catalogModelMissing = "catalog_model_missing"
    case metadataMissing = "metadata_missing"
    case metadataMalformed = "metadata_malformed"
    case artifactNotCached = "artifact_not_cached"
    case manifestFetchFailed = "manifest_fetch_failed"
    case manifestMalformed = "manifest_malformed"
    case manifestDigestMismatch = "manifest_digest_mismatch"
    case manifestBindingMismatch = "manifest_binding_mismatch"
    case artifactOversize = "artifact_oversize"
    case fileCountInvalid = "file_count_invalid"
    case fileTypeDisallowed = "file_type_disallowed"
    case pathInvalid = "path_invalid"
    case fileDownloadFailed = "file_download_failed"
    case fileDigestMismatch = "file_digest_mismatch"
    case warmArtifactCorrupt = "warm_artifact_corrupt"
    case publicationFailed = "publication_failed"
    case assistantLoadFailed = "assistant_load_failed"
    case assistantTargetIncompatible = "assistant_target_incompatible"
    case assistantMemoryUnavailable = "assistant_memory_unavailable"
    case assistantResliceFloor = "assistant_reslice_floor"
    case assistantPostBuildHeadroom = "assistant_post_build_headroom"
    case engineInactive = "engine_inactive"
    /// ENABLED BUT INERT — the one reason that is not a load failure. The
    /// drafter loaded, the engine reports MTP active, and yet not one round
    /// has run because every planned row was skipped as `kv_unsupported`
    /// (`EngineLoopV2+MTPPlanning.mtpPlanAction`). Today's shape: a paged
    /// gemma-4 slot, whose windowed layers the drafter's KV path cannot
    /// serve — it charges full drafter residency and returns nothing.
    /// Distinct from `engineInactive`, where the engine says it is OFF;
    /// here the engine says it is ON and produces nothing, which is why
    /// this state was invisible until it was given a name.
    case inertKVUnsupported = "inert_kv_unsupported"
}

public enum SpecDecArtifactSource: String, Sendable, Equatable {
    case local
    case catalog
}

/// A verified assistant directory and the facts used before model admission.
struct SpecDecArtifact: Sendable, Equatable {
    let directory: URL
    let source: SpecDecArtifactSource
    let revision: String
    let artifactBytes: UInt64
    let residentBytes: UInt64
    let manifestSHA256: String?
    /// Immutable inspection-time digests for every local weight file. Catalog
    /// artifacts use their signed manifest instead.
    let localWeightSHA256: [String: String]?
    /// Full local config digest retained separately from the display revision;
    /// the revision intentionally contains only a short, non-secret prefix.
    let localConfigSHA256: String?
    /// Catalog artifacts retain the complete immutable trust reference used to
    /// verify them. Local operator overrides intentionally have no catalog trust.
    let catalogReference: SpecDecArtifactReference?

    init(
        directory: URL,
        source: SpecDecArtifactSource,
        revision: String,
        artifactBytes: UInt64,
        residentBytes: UInt64,
        manifestSHA256: String?,
        localWeightSHA256: [String: String]? = nil,
        localConfigSHA256: String? = nil,
        catalogReference: SpecDecArtifactReference? = nil
    ) {
        self.directory = directory
        self.source = source
        self.revision = revision
        self.artifactBytes = artifactBytes
        self.residentBytes = residentBytes
        self.manifestSHA256 = manifestSHA256
        self.localWeightSHA256 = localWeightSHA256
        self.localConfigSHA256 = localConfigSHA256
        self.catalogReference = catalogReference
    }
}

struct SpecDecResolution: Sendable, Equatable {
    let artifact: SpecDecArtifact?
    let reason: MTPFallbackReason?
    let detail: String?

    static func resolved(_ artifact: SpecDecArtifact) -> Self {
        Self(artifact: artifact, reason: nil, detail: nil)
    }

    static func fallback(_ reason: MTPFallbackReason, detail: String? = nil) -> Self {
        Self(artifact: nil, reason: reason, detail: detail)
    }
}

/// Slot-visible MTP state. `artifactBytes` describes the resolved artifact;
/// `assistantBytes` is the resident estimate and is zero on every fallback.
struct MTPActivationStatus: Sendable, Equatable {
    let configured: Bool
    let active: Bool
    let reason: MTPFallbackReason?
    let source: SpecDecArtifactSource?
    let revision: String?
    let artifactBytes: UInt64
    let assistantBytes: UInt64

    static func disabled(_ reason: MTPFallbackReason, configured: Bool) -> Self {
        Self(
            configured: configured, active: false, reason: reason, source: nil,
            revision: nil, artifactBytes: 0, assistantBytes: 0)
    }

    static func candidate(_ artifact: SpecDecArtifact) -> Self {
        Self(
            configured: true, active: false, reason: nil, source: artifact.source,
            revision: artifact.revision, artifactBytes: artifact.artifactBytes,
            assistantBytes: 0)
    }

    func activated(assistantBytes: UInt64) -> Self {
        Self(
            configured: configured, active: true, reason: nil, source: source,
            revision: revision, artifactBytes: artifactBytes,
            assistantBytes: assistantBytes)
    }

    func fallingBack(_ reason: MTPFallbackReason) -> Self {
        Self(
            configured: configured, active: false, reason: reason, source: source,
            revision: revision, artifactBytes: artifactBytes, assistantBytes: 0)
    }
}

struct SpecDecPreparation: Sendable, Equatable {
    let artifact: SpecDecArtifact?
    let status: MTPActivationStatus

    func fallingBack(_ reason: MTPFallbackReason) -> Self {
        Self(artifact: nil, status: status.fallingBack(reason))
    }
}

enum SpecDecLimits {
    static let maximumPrefixBytes = 512
    static let maximumManifestBytes = 1 * 1024 * 1024
    /// Current Gemma 4 assistants are a few hundred MiB. Two GiB leaves ample
    /// publication headroom without allowing optional drafting to trigger an
    /// 8 GiB verification/read workload on a target-serving process.
    static let maximumArtifactBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maximumConfigBytes: UInt64 = 1 * 1024 * 1024
    static let maximumFileCount = 64
    static let maximumFileNameBytes = 255
    static let maximumRevisionBytes = 256
    static let residentMultiplier = 1.20
    static let allowedRoles: Set<String> = ["config", "weight"]

    static func residentEstimate(artifactBytes: UInt64) -> UInt64 {
        guard artifactBytes > 0 else { return 0 }
        let estimate = (Double(artifactBytes) * residentMultiplier).rounded(.up)
        guard estimate.isFinite, estimate < Double(UInt64.max) else { return .max }
        return UInt64(estimate)
    }
}
