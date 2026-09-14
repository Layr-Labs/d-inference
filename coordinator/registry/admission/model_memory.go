package admission

const (
	// servabilityCapFraction mirrors the provider's UnifiedMemoryCap default
	// (90% of physical memory usable for MLX).
	servabilityCapFraction = 0.90
	// servabilityActivationFloorGB mirrors the provider's DEFAULT activation
	// reserve (UnifiedMemoryCap.defaultActivationReserveBytes, 5.5 GiB): the
	// working set held back on top of weights before any KV cache. On
	// pre-per-model binaries it is FLAT — every model, every attention
	// posture, every batch; on per-model binaries it is the fallback for
	// models without a measured floor (servabilityModelActivationFloorsGB).
	//
	// 5.5 as of v0.8.0, moved in the SAME commit as the provider constant:
	// the release ships decode batch 8 and the measured gemma-4 B=8
	// activation peak is 5.05 GiB, above the old 3 GiB floor (which was
	// sized against the B=4 sweep). The coordinator consequence is a smaller
	// predicted cold post-load budget — 2.5 GiB / 400000 B-per-token ≈ 6.7k
	// fewer tokens per box — which is the deliberate, protective direction:
	// the provider now genuinely leaves that much less KV.
	//
	// A per-token surcharge for composed-attention models (head_dim outside
	// MLX's fused-SDPA set {64, 80, 128}) briefly lived beside it and has been
	// removed: the provider half it claimed to mirror was never wired, so the
	// coordinator was charging for a reserve no provider ever held. See
	// ColdTokenBudgetEstimate's "Mirroring, not modelling" note before adding
	// any term here. That note still governs: the per-model floors below are
	// NOT a second opinion about prefill memory — they mirror the measured
	// floors the provider's own UnifiedMemoryCap now holds, exactly as this
	// flat constant mirrors its default. A term the provider does not hold
	// remains unsanctioned.
	servabilityActivationFloorGB = 5.5
	// servabilityLegacyActivationFloorGB is the reserve a pre-0.8.0 provider
	// actually holds (the old defaultActivationReserveBytes). During the
	// staged rollout the fleet is mixed, and this mirror must charge each
	// provider the reserve ITS binary holds — a flat 5.5 against a cold
	// legacy box falsely 429s (prompt_too_long, terminal) a request sized
	// between the two reserves that the legacy fleet could serve. See
	// ActivationFloor.
	servabilityLegacyActivationFloorGB = 3.0
	// servabilityActivationFloorMinVersion is the first provider release
	// whose UnifiedMemoryCap holds the 5.5 GiB reserve.
	servabilityActivationFloorMinVersion = "0.8.0"
	// servabilityPerModelFloorMinVersion is the first provider release whose
	// UnifiedMemoryCap resolves the activation reserve from its serving set
	// via the measured per-model floor table.
	//
	// RELEASE COUPLING: the release that ships the provider half of this
	// change MUST be numbered exactly this (or this constant updated in the
	// release commit — see the Releases section of CLAUDE.md, which bumps
	// ProviderCore.version in the same commit). Plain numeric only:
	// providerversion.Policy.Compare parses non-numeric segments as 0, so a "-swift.N"
	// suffix would make every per-model binary read as BELOW this gate and
	// be charged the flat floor (the unsanctioned tighter direction).
	// This branch bumps ProviderCore.version to 0.8.16 in the same tree,
	// honoring the coupling; 0.8.11 through 0.8.15 binaries hold the flat
	// 5.5 and are gated below by this value.
	servabilityPerModelFloorMinVersion = "0.8.16"
)

// servabilityModelActivationFloorsGB mirrors the provider's measured
// per-model activation floors (UnifiedMemoryCap.measuredActivationFloorsBytes);
// the two tables MUST move in the same commit. Keys are catalog model ids,
// EXACT match only — a hot-swapped build id ("gpt-oss-20b--r2"-style) misses
// the table on BOTH sides in lockstep (no desync; the tier reverts to the
// flat default until the new build is measured and added here).
// gpt-oss-20b: measured B=8 activation peak 2.56 GiB eager / 3.20 GiB
// compiled (fused SDPA, head_dim 64; same benchmark sweep that sized the
// 5.5 GiB default off gemma-4's 5.05/5.34) + slack → 3.5.
//
// For a multi-model provider this figure is a LOWER bound on the reserve it
// actually holds (its UnifiedMemoryCap takes the max over the whole serving
// set, which the coordinator does not know) — the optimistic direction this
// file sanctions: the worst case is a declined load — or a load that
// succeeds and has its first submit rejected as a capacity 503 (clamp +
// reroute) — both absorbed by the dispatch retry machinery, and the warm
// report replaces the estimate once the slot loads.
var servabilityModelActivationFloorsGB = map[string]float64{
	// Raw peak-over-resident @500-token B=8 basis (July 2026 sweep;
	// compiled 3.20 + slack — the current engine measures 2.63 raw).
	"gpt-oss-20b": 3.5,
	// qwen3.5/3.6 (measured text-decode envelope ~3.3 GiB) are
	// deliberately ABSENT pending a vision-inclusive measurement — they are
	// vision-capable and the tower transient rides the reserve this floor
	// sizes. Mirrors the provider table's absence — same commit.
}

// servabilityMeasuredResidentGiB is the CANONICAL measured post-load MLX
// residency table (GiB, +~2% slack; TEXT-ONLY artifacts, current engine,
// 2026-08-30/31 sweep — docs/reports/2026-08-30-activation-floor-measurements.md).
// It feeds ONLY ColdTokenBudgetEstimate — the POST-load token-budget
// arithmetic, where steady residency is the physically correct weights
// term (the estimate converges to the provider's own warm
// active_token_budget_max, which reflects steady residency). It must NOT
// feed any ADMIT-time gate: the provider's load gate deliberately charges
// the padded disk×1.2 figure because the LOAD TRANSIENT (shard staging)
// exceeds steady residency — see ReportedFreeForLoadAdmits. There is no
// provider-side twin by design (the provider holds no load-time measured
// constant); the mirror obligation here is to the measured physical truth
// in the report, re-measured per engine release. Vision-capable models are
// deliberately ABSENT: text-only bench residency under-counts the tower.
var servabilityMeasuredResidentGiB = map[string]float64{
	// measured 11.25 active; model_type gpt_oss has no VLM wrapper, so the
	// bench's LLM-factory load IS the production load path.
	"gpt-oss-20b": 11.5,
	// gemma-4-26b/-8bit (24.97 measured TEXT-path) are deliberately
	// ABSENT: their artifact carries vision_config (model_type gemma4), so
	// production loads the tower too and the text-path figure under-counts
	// residency. Padded until a provider-path (VLM) measurement exists.
}

// ColdWeightsGiB is the weights term of the POST-LOAD
// token-budget arithmetic (ColdTokenBudgetEstimate) for the given provider
// binary and model: measured steady residency for ≥perModel binaries on
// measured models, the catalog-padded conversion otherwise. Version-gated
// like ActivationFloor so pre-perModel binaries — whose warm
// reports the estimate converges to under the OLD arithmetic — keep the
// padded prediction. ADMIT-time gates never call this (see
// ReportedFreeForLoadAdmits: the load transient needs the padding).
func (p Policy) ColdWeightsGiB(version, modelID string, catalogSizeGB float64) float64 {
	padded := catalogSizeGB * coldLoadCatalogGBToMemGiB
	if version == "" ||
		p.versions.Compare(version, servabilityPerModelFloorMinVersion) < 0 {
		return padded
	}
	if measured, ok := servabilityMeasuredResidentGiB[modelID]; ok {
		return measured
	}
	return padded
}

// ActivationFloor selects the activation reserve the given
// provider binary actually holds for the given model. This is the same
// version-gated selection shape as slotBudgetLayoutForVersion: the registry
// snapshot carries the provider's reported binary version (p.Version →
// snap.binaryVersion) and the model being routed (snap.model), so the cold
// estimate can mirror the right constant per provider — which is what makes
// it converge to that provider's own warm report as the slot loads (a legacy
// provider's active_token_budget_max reflects its 3 GiB reserve; a per-model
// provider's reflects its serving-set floor).
//
// Three regimes: pre-0.8.0 binaries hold the legacy flat 3 GiB; 0.8.0 up to
// (excluding) the per-model release hold the flat 5.5 GiB; per-model binaries
// hold the measured floor for models in the mirrored table and the flat 5.5
// otherwise.
//
// An EMPTY/unreported version fails toward the LEGACY (larger) budget, the
// fail-open direction this file mandates: over-predicting a budget risks one
// provider-side refusal that the dispatch retry machinery absorbs;
// under-predicting produces a terminal client-visible 429. The asymmetry is
// also self-correcting — the fleet trends to ≥0.8.0 as it upgrades, and every
// RESIDENT slot reports its real budget, which StructuralBudget
// prefers over this estimate.
func (p Policy) ActivationFloor(version, modelID string) float64 {
	if version == "" ||
		p.versions.Compare(version, servabilityActivationFloorMinVersion) < 0 {
		return servabilityLegacyActivationFloorGB
	}
	if p.versions.Compare(version, servabilityPerModelFloorMinVersion) < 0 {
		return servabilityActivationFloorGB
	}
	if floor, ok := servabilityModelActivationFloorsGB[modelID]; ok {
		return floor
	}
	return servabilityActivationFloorGB
}
