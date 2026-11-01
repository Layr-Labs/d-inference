import Foundation

/// The Autopilot model set reported as `selected_models` and used by every
/// Autopilot gate on a machine with saved consent: the operator's persisted
/// selection plus every verified catalog build in the local cache that this
/// machine can run. No new consent step widens it; the saved Autopilot opt-in
/// is the gate, and a machine without it has no set at all.
public enum AutopilotModelSet {
    /// The coordinator fences a machine whose report exceeds 256 selected IDs
    /// (`boundedState`), so the union is capped and the persisted selection
    /// keeps priority.
    public static let maximumCount = 256

    /// IDs the provider adds on its own are 1...256 bytes of visible ASCII:
    /// a control character or a space in a report fences the whole machine,
    /// and operation APIs accept only visible ASCII.
    public static func isReportableID(_ id: String) -> Bool {
        let bytes = id.utf8
        return !bytes.isEmpty && bytes.count <= 256 && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }

    /// Persisted selection first, then cached builds in ID order, capped at
    /// `maximumCount`, sorted for a deterministic report.
    public static func effective(selected: [String], cached: some Sequence<String>) -> [String] {
        var members = Set<String>()
        for id in selected where members.count < maximumCount { members.insert(id) }
        for id in Set(cached).sorted() where members.count < maximumCount && isReportableID(id) {
            members.insert(id)
        }
        return members.sorted()
    }
}

/// The opt-in picker's default-selection rules, shared by enrollment, the
/// daemon's start-time Autopilot set and Autopilot downloads: an active
/// catalog build whose hardware gates this machine meets, served by a
/// supported engine family within the load budget, whose local bytes are the
/// catalog's current build.
public enum AutopilotBuildEligibility {
    /// The provider's cap less the activation and minimum KV headroom: the
    /// largest footprint the picker offers. Catalog estimates are conservative;
    /// the loader rechecks live memory before any load.
    public static func loadBudgetGiB(memoryGb: Double, modelIDs: [String]? = nil) -> Double {
        guard memoryGb.isFinite, memoryGb > 0, memoryGb <= 4096 else { return 0 }
        let gib = Double(1 << 30)
        let cap = Double(UnifiedMemoryCap.hardCapBytes(physicalBytes: UInt64(memoryGb * gib))) / gib
        return max(0, cap - Double(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: modelIDs)) / gib)
    }

    public static func fitsLoadBudget(sizeGb: Double, memoryGb: Double, modelIDs: [String]? = nil) -> Bool {
        sizeGb.isFinite && sizeGb > 0 && sizeGb <= loadBudgetGiB(memoryGb: memoryGb, modelIDs: modelIDs)
    }

    /// Gates that need only the catalog: what a download may be refused on
    /// before any byte is fetched.
    public static func catalogAllows(_ entry: CatalogModel, memoryGb: Double,
                                     runtimeCapabilities: Set<ProviderRuntimeCapability>) -> Bool {
        entry.active != false && (entry.minRamGb ?? 0) <= Int(memoryGb)
            && !entry.id.isEmpty && entry.id.utf8.count <= 256
            && ModelRuntimeRequirements.isEligible(modelID: entry.id,
                catalogRequirements: entry.requiredProviderCapabilities, available: runtimeCapabilities)
    }

    /// Gates that need only the scanned build: a supported engine family
    /// within the load budget.
    public static func allowsScannedBuild(_ model: ModelInfo, memoryGb: Double) -> Bool {
        EngineV2SupportedModels.isSupported(model: model)
            && fitsLoadBudget(sizeGb: model.estimatedMemoryGb, memoryGb: memoryGb)
    }

    /// The catalog gates plus the scanned build's.
    public static func allowsCachedBuild(_ model: ModelInfo, entry: CatalogModel, memoryGb: Double,
                                         runtimeCapabilities: Set<ProviderRuntimeCapability>) -> Bool {
        model.id == entry.id && catalogAllows(entry, memoryGb: memoryGb, runtimeCapabilities: runtimeCapabilities)
            && allowsScannedBuild(model, memoryGb: memoryGb)
    }

    /// Whether a locally computed weight hash is the catalog's current build:
    /// the hash the coordinator checks provider builds against, else the
    /// manifest aggregate a managed revision is verified by.
    public static func isCurrentCatalogBuild(weightHash: String?, entry: CatalogModel) -> Bool {
        guard let hash = weightHash, !hash.isEmpty else { return false }
        return [entry.weightHash, entry.aggregateSHA256].contains { expected in
            expected.map { !$0.isEmpty && $0.caseInsensitiveCompare(hash) == .orderedSame } ?? false
        }
    }
}
