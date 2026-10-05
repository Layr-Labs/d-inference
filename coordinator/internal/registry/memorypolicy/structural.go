// Package memorypolicy evaluates physical admission and structural serviceability
// on detached inputs. It never reserves capacity or decides provider eligibility.
package memorypolicy

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

// DefaultRequestedMaxTokens is the coordinator's fallback request reservation,
// not a provider context limit or a billing quantity.
const DefaultRequestedMaxTokens = 256

const (
	// servabilityCapFraction mirrors the provider's UnifiedMemoryCap default
	// (90% of physical memory usable for MLX).
	servabilityCapFraction = 0.90
	// servabilityActivationFloorGB mirrors the provider's DEFAULT activation
	// reserve (UnifiedMemoryCap.defaultActivationReserveBytes, 5.5 GiB): the
	// working set held back on top of weights before any KV cache. It is the
	// fallback for models without a measured floor
	// (servabilityModelActivationFloorsGB) — every such model, every attention
	// posture, every batch.
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
	// coldTokenBudgetEstimate's "Mirroring, not modelling" note before adding
	// any term here. That note still governs: the per-model floors below are
	// NOT a second opinion about prefill memory — they mirror the measured
	// floors the provider's own UnifiedMemoryCap now holds, exactly as this
	// flat constant mirrors its default. A term the provider does not hold
	// remains unsanctioned.
	servabilityActivationFloorGB = 5.5
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
// It feeds ONLY coldTokenBudgetEstimate — the POST-load token-budget
// arithmetic, where steady residency is the physically correct weights
// term (the estimate converges to the provider's own warm
// active_token_budget_max, which reflects steady residency). It must NOT
// feed any ADMIT-time gate: the provider's load gate deliberately charges
// the padded disk×1.2 figure because the LOAD TRANSIENT (shard staging)
// exceeds steady residency — see reportedFreeForLoadAdmits. There is no
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
// token-budget arithmetic (coldTokenBudgetEstimate) for the given model:
// measured steady residency for measured models, the catalog-padded
// conversion otherwise. ADMIT-time gates never call this (see
// reportedFreeForLoadAdmits: the load transient needs the padding).
func ColdWeightsGiB(modelID string, catalogSizeGB float64) float64 {
	if measured, ok := servabilityMeasuredResidentGiB[modelID]; ok {
		return measured
	}
	return catalogSizeGB * admission.ColdLoadCatalogGBToMemGiB
}

// ActivationFloor selects the activation reserve the provider holds
// for the given model: the measured floor for models in the mirrored table
// (servabilityModelActivationFloorsGB), the flat servabilityActivationFloorGB
// otherwise. The snapshot carries the model being routed (snap.model), so the
// cold estimate converges to that provider's own warm report as the slot
// loads (a resident slot's active_token_budget_max reflects its serving-set
// floor).
func ActivationFloor(modelID string) float64 {
	if floor, ok := servabilityModelActivationFloorsGB[modelID]; ok {
		return floor
	}
	return servabilityActivationFloorGB
}

// ColdTokenBudgetWithOffload approximates the token budget a cold (on-disk, not yet
// loaded) provider would have AFTER loading the model. The provider holds back a
// flat activation reserve on top of the padded weights, so the budget is
//
//	(cap*totalMemoryGB - paddedWeightsGB - activationFloor) / kvBytesPerToken
//
// paddedWeightsGB uses the same catalog→padded-GiB conversion the cold-load gate
// uses (coldLoadCatalogGBToMemGiB). kvBytesPerToken prefers the provider-reported
// per-model value, falling back to the kvCacheBytesPerToken default.
// modelID selects the activation reserve the provider holds for THAT model —
// the measured per-model floor, else the flat 5.5 GiB
// (servabilityActivationFloor) — and the measured post-load residency when
// one exists (servabilityColdWeightsGiB). The estimate is deliberately
// OPTIMISTIC (uses only the activation
// reserve, not the extra min-KV load floor) so the predictor errs toward
// serving. Returns 0 when the inputs are unusable or no headroom remains.
//
// # Mirroring, not modelling
//
// This function's only job is to reproduce the PROVIDER's own reserve arithmetic
// for a slot that has no heartbeat yet. It is not an independent opinion about
// how much memory prefill needs. UnifiedMemoryCap.kvBudgetBytes computes
// cap − Σweights − reserve with reserve the serving set's floor, and a resident slot
// reports exactly that back as active_token_budget_max (EngineV2Bridge+Capacity:
// kvBytesCapacity / kvBytesPerToken) — which snapshotStructuralBudget prefers
// whenever it exists. So the cold estimate has to converge to the warm report as
// the slot loads, and it does, because both are the same subtraction.
//
// That is why there is no attention-posture term here. A composed-attention
// model (gemma-4: head_dim 256 sliding / 512 full) really does materialise a
// bigger prefill score tensor than a fused one (gpt-oss: head_dim 64, inside
// MLX's fused-SDPA set), but the provider does not charge a posture term —
// its reserve is the measured per-model floor (or the flat default), never a
// shape estimate. Charging a term the provider does not hold made this gate
// strictly TIGHTER than the gate it mirrors and 429'd prompts every provider
// in the fleet could have served. Whether a floor is the right number is the
// provider's question, answered in one place; a second opinion here can only
// desync. Retune this ONLY when the provider's floors move — as they did for
// v0.8.0 (3 → 5.5, the measured B=8 activation peak) and again when the
// measured per-model table shipped (v0.8.16). Convergence is per-provider:
// while any provider below a floor move is still routable (above
// EIGENINFERENCE_MIN_PROVIDER_VERSION), the mirror must charge each binary
// the reserve it actually holds, version-gated.
//
// Being optimistic is the safe direction because the coordinator is not the
// backstop. The provider is, and its checks are measurement-based, not
// estimates: the load gate refuses a model that cannot clear reserve + 1 GiB of
// serveable KV (loadHeadroomBytes), the post-load probe unloads one whose
// MEASURED live KV headroom is below that (loadIsServeable), and every
// reservation is checked against real MLX active+cache bytes
// (liveKVHeadroomBytes). An over-generous estimate therefore costs a declined
// load, which the dispatch path retries elsewhere — strictly better than a
// terminal 429 on a request that was servable all along.
func ColdTokenBudgetWithOffload(TotalMemoryGB, ModelSizeGB, offloadedMemoryGB float64, KVBytesPerToken int64, modelID string) int64 {
	if TotalMemoryGB <= 0 || ModelSizeGB <= 0 {
		return 0
	}
	weightsGB := ColdWeightsGiB(modelID, ModelSizeGB)
	if capacityvalue.FinitePositive(offloadedMemoryGB) {
		weightsGB = offloadedMemoryGB
	}
	postLoadGB := servabilityCapFraction*TotalMemoryGB - weightsGB
	if postLoadGB <= 0 {
		return 0
	}
	kvpt := KVBytesPerToken
	if kvpt <= 0 {
		kvpt = admission.KVCacheBytesPerToken
	}
	postLoadBytes := postLoadGB * float64(admission.BytesPerGB)
	floorBytes := ActivationFloor(modelID) * float64(admission.BytesPerGB)
	tokens := (postLoadBytes - floorBytes) / float64(kvpt)
	if tokens <= 0 {
		return 0
	}
	return int64(tokens)
}

// StructuralBudget returns this provider's structural token-budget
// contribution for the model, and whether it is known. A resident slot uses the
// provider-reported active_token_budget_max — which already nets out whatever
// activation reserve that provider actually chose. A cold-but-fitting provider
// has no such report, so it uses the optimistic post-load estimate, reserve
// included (see coldTokenBudgetEstimate). "known=false" means we cannot tell
// (legacy resident slot with no budget, or missing memory data) — the caller
// treats unknown as fail-open and skips the budget tier entirely.
func StructuralBudget(snap *Input) (budget int64, known bool) {
	if snap.ActiveTokenBudgetMax > 0 {
		return snap.ActiveTokenBudgetMax, true
	}
	if snap.ModelLoaded {
		// Resident but no token budget reported (legacy provider): unknown.
		return 0, false
	}
	// Cold/on-disk: estimate the post-load budget. Needs memory + size data.
	if snap.TotalMemoryGB <= 0 || snap.ModelSizeGB <= 0 {
		return 0, false
	}
	return ColdTokenBudgetWithOffload(
		snap.TotalMemoryGB, snap.ModelSizeGB, snap.EstimatedOffloadedMemoryGB, snap.KVBytesPerToken,
		snap.Model), true
}

// liveRemainingBudget is StructuralBudget minus the provider's CURRENTLY
// committed tokens (active + queued) for resident slots: a 50k request fits an
// idle 131k box but NOT one already holding 100k. Cold/on-disk slots keep the
// optimistic post-load estimate (nothing is committed there yet). Same fail-open
// contract as snapshotStructuralBudget (known=false ⇒ skip).
//
// This live math backs ONLY per-provider admission (providerBudgetFits →
// freeMemoryAdmits), where a "doesn't fit right now" is a capacity rejection
// that queues. It must NOT feed the fleet-level servability shed, which is
// structural-only (see PredictServable) — a live-remaining fleet 429 would shed
// a merely-busy fleet ahead of the queue.
func liveRemainingBudget(snap *Input) (budget int64, known bool) {
	if snap.ActiveTokenBudgetMax > 0 {
		// Gray-box budget clamp (budget_clamp.go): a capacity-503 proved the
		// live gate rejects, so the pair's LIVE headroom is zero regardless of
		// the stale-optimistic heartbeat budget. Live-semantics readers only —
		// the STRUCTURAL ceiling (snapshotStructuralBudget → PredictServable)
		// stays raw on purpose: the clamp is transient (TTL-bounded) and must
		// never feed the fleet-level structural 429.
		if snap.BudgetClamped {
			return 0, true
		}
		rem := snap.ActiveTokenBudgetMax - snap.ActiveTokenBudgetUsed - snap.QueuedTokenBudget
		if rem < 0 {
			rem = 0
		}
		return rem, true
	}
	return StructuralBudget(snap)
}

// BudgetFits reports whether a request of (prompt + max_tokens) tokens
// fits this provider's LIVE token budget, computed with the same math the
// provider's own admission enforces — the per-provider mirror of the fleet
// tier, exposed for the scheduler's free-memory admission gate
// (freeMemoryAdmits):
//
//   - Resident slot: the provider rejects when
//     activeUsed + (promptTokens + maxTokens) > tokenBudgetMax
//     (BatchScheduler submitTokenized / EngineV2Bridge submitTokenized), so the
//     fit is request ≤ max − used − queued (liveRemainingBudget). Unlike the
//     fleet servability tier, this per-provider check keeps LIVE semantics on
//     purpose: its "no" is a capacity rejection that falls into the queue, not
//     a terminal 429.
//   - Cold/on-disk slot: the provider's load gate only guarantees the load
//     headroom above the weights (UnifiedMemoryCap.loadHeadroomBytes ≈
//     activation reserve + 1 GiB of serveable KV, ~2.7k tokens), so a load can
//     succeed and the FIRST submit still reject with token_budget_exhausted
//     when the request exceeds the post-load budget. The fit uses the same
//     post-load estimate as the fleet tier (coldTokenBudgetEstimate) — a
//     weight-only cold check is exactly the admit→503 gap.
//
// known=false means the budget cannot be computed (legacy resident slot with
// no reported budget, or missing memory/size data) and the caller must fail
// open. A reqMaxTokens ≤ 0 is normalized to defaultRequestedMaxTokens, the
// same defaulting the pending-budget accounting applies.
func BudgetFits(snap *Input, reqPromptTokens, reqMaxTokens int) (fits, known bool) {
	budget, known := liveRemainingBudget(snap)
	if !known {
		return true, false
	}
	prompt := reqPromptTokens
	if prompt < 0 {
		prompt = 0
	}
	maxTok := reqMaxTokens
	if maxTok <= 0 {
		maxTok = DefaultRequestedMaxTokens
	}
	return int64(prompt)+int64(maxTok) <= budget, true
}
