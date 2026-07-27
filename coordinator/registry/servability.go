package registry

// Servability prediction.
//
// The coordinator's free-memory admission gate (freeMemoryAdmits) is, on the
// COLD path, weight-only: it checks that a model's weights fit a provider's
// reported free_for_load_gb but discards the KV-cache requirement. So a long
// prompt can be admitted onto a provider that can LOAD gpt-oss but whose
// post-load token budget cannot hold (prompt + max_tokens). The provider then
// rejects with token_budget_exhausted / insufficient KV headroom and the request
// fails as a 5xx — an uptime-damaging "admitted_but_failed" (the dominant
// gpt-oss OpenRouter failure mode after TTFT_HARD_REJECT was disabled).
//
// PredictServable answers a narrow, structural question BEFORE we admit/dispatch:
// "is there any provider in the fleet that could ever serve a request of this
// size?" — i.e. does (prompt + max_tokens) fit the model's context window AND
// some provider's structural token budget. When the answer is a confident NO,
// the caller returns an uptime-NEUTRAL early 429 (OpenRouter fails over) instead
// of admit→5xx.
//
// Design invariants:
//   - FAIL OPEN. Whenever the data needed to decide is missing or ambiguous, the
//     verdict is Servable=true. This predictor must never reintroduce the blunt
//     over-rejection of the old global TTFT_HARD_REJECT — it only rejects clearly
//     unservable requests; everything else is left to the normal capacity path
//     and the dispatch-exhausted backstop.
//   - It mirrors the provider gate's two real limits: the model context window
//     and the per-slot token budget. The token-budget tier uses the provider's
//     own reported active_token_budget_max for resident slots and an optimistic
//     cold estimate (see coldTokenBudgetEstimate) for on-disk slots.
//   - STRUCTURAL ONLY. The token-budget tier compares against each provider's
//     budget CEILING, never the live remaining budget (ceiling minus active +
//     queued tokens). A request that fits some ceiling but not the current live
//     headroom is merely arriving on a BUSY fleet — that is transient fullness,
//     owned by the capacity/queue path (queue-before-shed), which holds the
//     request until a slot frees. This gate may 429 only requests that could
//     NEVER be served no matter how long they waited.
//   - The prompt-token input is the routing estimate (len/4), which UNDER-counts
//     real tokens; that is the safe direction here (under-count → less likely to
//     reject), with the dispatch-exhausted reclassification catching whatever the
//     estimate misses.

const (
	// servabilityCapFraction mirrors the provider's UnifiedMemoryCap default
	// (90% of physical memory usable for MLX).
	servabilityCapFraction = 0.90
	// servabilityActivationFloorGB mirrors the provider's activation reserve
	// (UnifiedMemoryCap.defaultActivationReserveBytes, 5.5 GiB): the working
	// set held back on top of weights before any KV cache. It is FLAT on the
	// provider — every model, every attention posture, every batch — so it is
	// flat here. It does not scale with anything.
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
	// any term here. Moving the FLAT floor — what this change does — is the
	// sanctioned shape; re-adding a model-dependent term is not.
	servabilityActivationFloorGB = 5.5
)

// ServabilityReason is the low-cardinality reason a request was judged
// structurally unservable. Empty when Servable.
type (
	ServabilityReason = string
)

const (
	// ServabilityContextExceeded: prompt + max_tokens exceeds the model's max
	// context window, so every provider would reject/truncate it.
	ServabilityContextExceeded ServabilityReason = "context_exceeded"
	// ServabilityPromptTooLong: prompt + max_tokens exceeds the largest token
	// budget any eligible provider can structurally offer (resident budget or
	// optimistic cold post-load budget).
	ServabilityPromptTooLong ServabilityReason = "prompt_too_long"
)

// ServabilityVerdict is the result of PredictServable. The numeric fields are
// exposed for telemetry and tests.
type ServabilityVerdict struct {
	Servable       bool
	Reason         ServabilityReason
	RequestTokens  int   // prompt + max_tokens (the provider's "requestBudget")
	ContextLimit   int   // model max context window (0 = unknown)
	FleetMaxBudget int64 // largest structural token budget across eligible providers (0 = none/unknown)
	ProviderCount  int   // eligible providers that could run the model at all
}

// coldTokenBudgetEstimate approximates the token budget a cold (on-disk, not yet
// loaded) provider would have AFTER loading the model. The provider holds back a
// flat activation reserve on top of the padded weights, so the budget is
//
//	(cap*totalMemoryGB - paddedWeightsGB - activationFloor) / kvBytesPerToken
//
// paddedWeightsGB uses the same catalog→padded-GiB conversion the cold-load gate
// uses (coldLoadCatalogGBToMemGiB). kvBytesPerToken prefers the provider-reported
// per-model value, falling back to the kvCacheBytesPerToken default. The estimate
// is deliberately OPTIMISTIC (uses only the activation reserve, not the extra
// min-KV load floor) so the predictor errs toward serving. Returns 0 when the
// inputs are unusable or no headroom remains.
//
// # Mirroring, not modelling
//
// This function's only job is to reproduce the PROVIDER's own reserve arithmetic
// for a slot that has no heartbeat yet. It is not an independent opinion about
// how much memory prefill needs. UnifiedMemoryCap.kvBudgetBytes computes
// cap − Σweights − reserve with reserve flat at 5.5 GiB, and a resident slot
// reports exactly that back as active_token_budget_max (EngineV2Bridge+Capacity:
// kvBytesCapacity / kvBytesPerToken) — which snapshotStructuralBudget prefers
// whenever it exists. So the cold estimate has to converge to the warm report as
// the slot loads, and it does, because both are the same subtraction.
//
// That is why there is no attention-posture term here. A composed-attention
// model (gemma-4: head_dim 256 sliding / 512 full) really does materialise a
// bigger prefill score tensor than a fused one (gpt-oss: head_dim 64, inside
// MLX's fused-SDPA set), but the provider does not charge it — UnifiedMemoryCap
// holds back 5.5 GiB either way. Charging it here made this gate strictly
// TIGHTER than the gate it mirrors and 429'd prompts every provider in the
// fleet could have served. Whether 5.5 GiB is the right number is the
// provider's question, answered in one place; a second opinion here can only
// desync. Retune this ONLY when defaultActivationReserveBytes moves — as it
// did for v0.8.0 (3 → 5.5, the measured B=8 activation peak).
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
func coldTokenBudgetEstimate(totalMemoryGB, modelSizeGB float64, kvBytesPerToken int64) int64 {
	if totalMemoryGB <= 0 || modelSizeGB <= 0 {
		return 0
	}
	paddedWeightsGB := modelSizeGB * coldLoadCatalogGBToMemGiB
	postLoadGB := servabilityCapFraction*totalMemoryGB - paddedWeightsGB
	if postLoadGB <= 0 {
		return 0
	}
	kvpt := kvBytesPerToken
	if kvpt <= 0 {
		kvpt = kvCacheBytesPerToken
	}
	postLoadBytes := postLoadGB * float64(bytesPerGB)
	floorBytes := servabilityActivationFloorGB * float64(bytesPerGB)
	tokens := (postLoadBytes - floorBytes) / float64(kvpt)
	if tokens <= 0 {
		return 0
	}
	return int64(tokens)
}

// snapshotStructuralBudget returns this provider's structural token-budget
// contribution for the model, and whether it is known. A resident slot uses the
// provider-reported active_token_budget_max — which already nets out whatever
// activation reserve that provider actually chose. A cold-but-fitting provider
// has no such report, so it uses the optimistic post-load estimate, reserve
// included (see coldTokenBudgetEstimate). "known=false" means we cannot tell
// (legacy resident slot with no budget, or missing memory data) — the caller
// treats unknown as fail-open and skips the budget tier entirely.
func snapshotStructuralBudget(snap routingSnapshot) (budget int64, known bool) {
	if snap.activeTokenBudgetMax > 0 {
		return snap.activeTokenBudgetMax, true
	}
	if snap.modelLoaded {
		// Resident but no token budget reported (legacy provider): unknown.
		return 0, false
	}
	// Cold/on-disk: estimate the post-load budget. Needs memory + size data.
	if snap.totalMemoryGB <= 0 || snap.modelSizeGB <= 0 {
		return 0, false
	}
	return coldTokenBudgetEstimate(snap.totalMemoryGB, snap.modelSizeGB, snap.kvBytesPerToken), true
}

// liveRemainingBudget is snapshotStructuralBudget minus the provider's CURRENTLY
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
func liveRemainingBudget(snap routingSnapshot) (budget int64, known bool) {
	if snap.activeTokenBudgetMax > 0 {
		// Gray-box budget clamp (budget_clamp.go): a capacity-503 proved the
		// live gate rejects, so the pair's LIVE headroom is zero regardless of
		// the stale-optimistic heartbeat budget. Live-semantics readers only —
		// the STRUCTURAL ceiling (snapshotStructuralBudget → PredictServable)
		// stays raw on purpose: the clamp is transient (TTL-bounded) and must
		// never feed the fleet-level structural 429.
		if snap.budgetClamped {
			return 0, true
		}
		rem := snap.activeTokenBudgetMax - snap.activeTokenBudgetUsed - snap.queuedTokenBudget
		if rem < 0 {
			rem = 0
		}
		return rem, true
	}
	return snapshotStructuralBudget(snap)
}

// providerBudgetFits reports whether a request of (prompt + max_tokens) tokens
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
func providerBudgetFits(snap routingSnapshot, reqPromptTokens, reqMaxTokens int) (fits, known bool) {
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
		maxTok = defaultRequestedMaxTokens
	}
	return int64(prompt)+int64(maxTok) <= budget, true
}

// PredictServable reports whether the fleet can structurally serve a request of
// the given size for the model. contextLimit is the model's max context window
// (from the model registry record; 0 = unknown → context tier skipped). It is
// read-only and fail-open (see file header). Self-route requests should not use
// this fleet-wide gate (they queue on the owner machine), matching the existing
// preflight which only runs for public routes.
//
// contextPromptTokens is the prompt-token count used ONLY for the context-window
// tier. It exists so a caller can feed a CALIBRATED estimate to the context tier
// (the len/4 routing estimate undercounts dense content) WITHOUT inflating the
// token-budget tier — the budget tier always uses the raw estimatedPromptTokens,
// so a calibration multiplier can never over-reject a request that fits a
// provider's real KV budget (a false-NO). Callers that don't calibrate pass
// contextPromptTokens == estimatedPromptTokens; a value below the raw estimate is
// floored to it (calibration only scales up).
func (r *Registry) PredictServable(model string, estimatedPromptTokens, contextPromptTokens, requestedMaxTokens, contextLimit int, traits RequestTraits, requiresVision bool, allowedSerials ...string) ServabilityVerdict {
	reqPrompt := estimatedPromptTokens
	if reqPrompt < 0 {
		reqPrompt = 0
	}
	reqContextPrompt := contextPromptTokens
	if reqContextPrompt < reqPrompt {
		reqContextPrompt = reqPrompt
	}
	reqMax := requestedMaxTokens
	if reqMax <= 0 {
		reqMax = defaultRequestedMaxTokens
	}
	budgetRequestTokens := reqPrompt + reqMax
	contextRequestTokens := reqContextPrompt + reqMax

	verdict := ServabilityVerdict{
		Servable:      true,
		RequestTokens: budgetRequestTokens,
		ContextLimit:  contextLimit,
	}

	// Tier 1: context window. Model-level and provider-agnostic. Exceeding the
	// model's context is a guaranteed failure on every provider. Uses the
	// (possibly calibrated) context-prompt count.
	if contextLimit > 0 && contextRequestTokens > contextLimit {
		verdict.Servable = false
		verdict.Reason = ServabilityContextExceeded
		verdict.RequestTokens = contextRequestTokens
		return verdict
	}

	// Tier 2: fleet token-budget ceiling. Find the largest structural budget any
	// eligible provider can offer. Fail open if any eligible provider's budget is
	// unknown (it might be larger than the request).
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	var fleetMax int64
	sawUnknown := false
	providerCount := 0
	for _, p := range r.providers {
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		snap, ok := r.snapshotProviderLocked(p, model, traits, false)
		if !ok {
			continue
		}
		// Modality (vision) is intentionally NOT filtered here: a vision-incapable
		// fleet for a vision request is a different rejection (handled by the
		// normal capacity path), and counting an extra provider's budget only makes
		// this size gate MORE lenient (fail-open). requiresVision is kept in the
		// signature for parity with QuickCapacityCheck* and future use.
		_ = requiresVision
		// A model that cannot fit this node at all is a model_too_large miss, not
		// a prompt-size problem — exclude it from the budget tier (the existing
		// preflight handles model_too_large). Resident models have demonstrably fit.
		if !snap.modelLoaded && !modelFitsHardware(snap.minRAMGb, snap.modelSizeGB, snap.totalMemoryGB) {
			continue
		}
		providerCount++
		// STRUCTURAL ceiling (resident: reported active_token_budget_max; cold:
		// optimistic post-load estimate) — deliberately NOT the live remaining
		// budget. Subtracting active+queued tokens here would classify a merely
		// BUSY fleet as prompt_too_long and 429 it before the queue-before-shed
		// path could hold the request for the seconds a slot takes to free.
		// Transient fullness belongs to the capacity/queue ladder; this tier
		// sheds only requests that exceed every ceiling and could NEVER fit.
		budget, known := snapshotStructuralBudget(snap)
		if !known {
			sawUnknown = true
			continue
		}
		if budget > fleetMax {
			fleetMax = budget
		}
	}

	verdict.FleetMaxBudget = fleetMax
	verdict.ProviderCount = providerCount

	// Reject on the budget tier only when EVERY eligible provider had a KNOWN
	// budget and none can hold the request. A known budget of 0 (a cold provider
	// whose weights leave no KV headroom) is a real "cannot serve", so it must
	// reject too — we gate on !sawUnknown, not fleetMax > 0, otherwise an
	// all-zero-budget fleet would fail open and dispatch into a guaranteed
	// provider-side token/KV rejection. Any unknown budget, or zero eligible
	// providers (a different rejection path owns that), still fails open.
	if providerCount > 0 && !sawUnknown && int64(budgetRequestTokens) > fleetMax {
		verdict.Servable = false
		verdict.Reason = ServabilityPromptTooLong
		return verdict
	}

	return verdict
}
