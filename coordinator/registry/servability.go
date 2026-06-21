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
//   - The prompt-token input is the routing estimate (len/4), which UNDER-counts
//     real tokens; that is the safe direction here (under-count → less likely to
//     reject), with the dispatch-exhausted reclassification catching whatever the
//     estimate misses.

const (
	// servabilityCapFraction mirrors the provider's UnifiedMemoryCap default
	// (90% of physical memory usable for MLX).
	servabilityCapFraction = 0.90
	// servabilityActivationReserveGB mirrors the provider's activation reserve
	// kept aside on top of weights before KV cache (UnifiedMemoryCap activation
	// reserve, ~3 GiB). Cold KV headroom ≈ cap*total - paddedWeights - reserve.
	servabilityActivationReserveGB = 3.0
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
// loaded) provider would have AFTER loading the model, mirroring the provider's
// own live-KV-headroom math:
//
//	kvHeadroomGB ≈ cap*totalMemoryGB - paddedWeightsGB - activationReserveGB
//	tokens       ≈ kvHeadroomGB * bytesPerGB / kvBytesPerToken
//
// paddedWeightsGB uses the same catalog→padded-GiB conversion the cold-load gate
// uses (coldLoadCatalogGBToMemGiB). kvBytesPerToken prefers the provider-reported
// per-model value, falling back to the kvCacheBytesPerToken default. The estimate
// is deliberately OPTIMISTIC (uses only the activation reserve, not the extra
// min-KV load floor) so the predictor errs toward serving. Returns 0 when the
// inputs are unusable or no headroom remains.
func coldTokenBudgetEstimate(totalMemoryGB, modelSizeGB float64, kvBytesPerToken int64) int64 {
	if totalMemoryGB <= 0 || modelSizeGB <= 0 {
		return 0
	}
	paddedWeightsGB := modelSizeGB * coldLoadCatalogGBToMemGiB
	kvHeadroomGB := servabilityCapFraction*totalMemoryGB - paddedWeightsGB - servabilityActivationReserveGB
	if kvHeadroomGB <= 0 {
		return 0
	}
	kvpt := kvBytesPerToken
	if kvpt <= 0 {
		kvpt = kvCacheBytesPerToken
	}
	tokens := int64(kvHeadroomGB * float64(bytesPerGB) / float64(kvpt))
	if tokens < 0 {
		return 0
	}
	return tokens
}

// snapshotStructuralBudget returns this provider's structural token-budget
// contribution for the model, and whether it is known. A resident slot uses the
// provider-reported active_token_budget_max; a cold-but-fitting provider uses the
// optimistic cold estimate. "known=false" means we cannot tell (legacy resident
// slot with no budget, or missing memory data) — the caller treats unknown as
// fail-open and skips the budget tier entirely.
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
