package registry

import "time"

// Servability prediction.
//
// The per-provider admission policy checks both cold-load weights and the
// post-load token budget. A model can fit a provider's reported free_for_load_gb
// while leaving too little KV capacity for (prompt + max_tokens); that is why
// the policy mirrors both limits. This fleet-level predictor asks the separate
// structural question below before routing or queueing on an individual node.
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
//     cold estimate (see admission.Policy.ColdTokenBudgetEstimate) for on-disk slots.
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
	now := time.Now()
	var snap routingSnapshot // one caller-owned buffer, refilled per provider
	// Per-model index: visit only providers advertising the model (gates
	// unchanged; see model_index.go).
	for _, p := range r.providersForModelLocked(model) {
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		if ok, _ := r.snapshotProviderIntoLockedEx(&snap, p, model, traits, false, false, now); !ok {
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
		budget, known := snapshotStructuralBudget(&snap)
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
