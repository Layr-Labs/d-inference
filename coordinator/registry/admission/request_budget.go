package admission

// ColdTokenBudgetEstimate approximates the token budget a cold (on-disk, not yet
// loaded) provider would have AFTER loading the model. The provider holds back a
// flat activation reserve on top of the padded weights, so the budget is
//
//	(cap*totalMemoryGB - paddedWeightsGB - activationFloor) / kvBytesPerToken
//
// paddedWeightsGB uses the same catalog→padded-GiB conversion the cold-load gate
// uses (coldLoadCatalogGBToMemGiB). kvBytesPerToken prefers the provider-reported
// per-model value, falling back to the DefaultKVBytesPerToken default.
// providerVersion and modelID select the activation reserve THAT binary holds
// for THAT model — 3 GiB before 0.8.0, flat 5.5 GiB up to the per-model
// release, then the measured per-model floor (ActivationFloor) —
// so a mixed-version fleet is charged per-provider, not at the newest
// constant. The estimate is deliberately OPTIMISTIC (uses only the activation
// reserve, not the extra min-KV load floor) so the predictor errs toward
// serving. Returns 0 when the inputs are unusable or no headroom remains.
//
// # Mirroring, not modelling
//
// This function's only job is to reproduce the PROVIDER's own reserve arithmetic
// for a slot that has no heartbeat yet. It is not an independent opinion about
// how much memory prefill needs. UnifiedMemoryCap.kvBudgetBytes computes
// cap − Σweights − reserve with reserve flat at 5.5 GiB, and a resident slot
// reports exactly that back as active_token_budget_max (EngineV2Bridge+Capacity:
// kvBytesCapacity / kvBytesPerToken) — which StructuralBudget prefers
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
// measured per-model table shipped — and keep the LEGACY constants beside it
// while any pre-move provider remains in the fleet: convergence is
// per-provider, so the mirror must charge each binary the reserve it actually
// holds (ActivationFloor).
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
func (p Policy) ColdTokenBudgetEstimate(totalMemoryGB, modelSizeGB float64, kvBytesPerToken int64, providerVersion, modelID string) int64 {
	if totalMemoryGB <= 0 || modelSizeGB <= 0 {
		return 0
	}
	weightsGB := p.ColdWeightsGiB(providerVersion, modelID, modelSizeGB)
	postLoadGB := servabilityCapFraction*totalMemoryGB - weightsGB
	if postLoadGB <= 0 {
		return 0
	}
	kvpt := kvBytesPerToken
	if kvpt <= 0 {
		kvpt = DefaultKVBytesPerToken
	}
	postLoadBytes := postLoadGB * float64(BytesPerGiB)
	floorBytes := p.ActivationFloor(providerVersion, modelID) * float64(BytesPerGiB)
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
// included (see ColdTokenBudgetEstimate). "known=false" means we cannot tell
// (legacy resident slot with no budget, or missing memory data) — the caller
// treats unknown as fail-open and skips the budget tier entirely.
func (p Policy) StructuralBudget(snap *Snapshot) (budget int64, known bool) {
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
	return p.ColdTokenBudgetEstimate(
		snap.TotalMemoryGB, snap.ModelSizeGB, snap.KVBytesPerToken,
		snap.BinaryVersion, snap.Model), true
}

// LiveRemainingBudget is StructuralBudget minus the provider's CURRENTLY
// committed tokens (active + queued) for resident slots: a 50k request fits an
// idle 131k box but NOT one already holding 100k. Cold/on-disk slots keep the
// optimistic post-load estimate (nothing is committed there yet). Same fail-open
// contract as StructuralBudget (known=false ⇒ skip).
//
// This live math backs ONLY per-provider admission (ProviderBudgetFits →
// FreeMemoryAdmits), where a "doesn't fit right now" is a capacity rejection
// that queues. It must NOT feed the fleet-level servability shed, which is
// structural-only (see PredictServable) — a live-remaining fleet 429 would shed
// a merely-busy fleet ahead of the queue.
func (p Policy) LiveRemainingBudget(snap *Snapshot) (budget int64, known bool) {
	if snap.ActiveTokenBudgetMax > 0 {
		// Gray-box budget clamp (faultstate/budget_clamp.go): a capacity-503 proved the
		// live gate rejects, so the pair's LIVE headroom is zero regardless of
		// the stale-optimistic heartbeat budget. Live-semantics readers only —
		// the STRUCTURAL ceiling (StructuralBudget → PredictServable)
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
	return p.StructuralBudget(snap)
}

// ProviderBudgetFits reports whether a request of (prompt + max_tokens) tokens
// fits this provider's LIVE token budget, computed with the same math the
// provider's own admission enforces — the per-provider mirror of the fleet
// tier, exposed for the scheduler's free-memory admission gate
// (FreeMemoryAdmits):
//
//   - Resident slot: the provider rejects when
//     activeUsed + (promptTokens + maxTokens) > tokenBudgetMax
//     (BatchScheduler submitTokenized / EngineV2Bridge submitTokenized), so the
//     fit is request ≤ max − used − queued (LiveRemainingBudget). Unlike the
//     fleet servability tier, this per-provider check keeps LIVE semantics on
//     purpose: its "no" is a capacity rejection that falls into the queue, not
//     a terminal 429.
//   - Cold/on-disk slot: the provider's load gate only guarantees the load
//     headroom above the weights (UnifiedMemoryCap.loadHeadroomBytes ≈
//     activation reserve + 1 GiB of serveable KV, ~2.7k tokens), so a load can
//     succeed and the FIRST submit still reject with token_budget_exhausted
//     when the request exceeds the post-load budget. The fit uses the same
//     post-load estimate as the fleet tier (ColdTokenBudgetEstimate) — a
//     weight-only cold check is exactly the admit→503 gap.
//
// known=false means the budget cannot be computed (legacy resident slot with
// no reported budget, or missing memory/size data) and the caller must fail
// open. A reqMaxTokens ≤ 0 is normalized to DefaultRequestedMaxTokens, the
// same defaulting the pending-budget accounting applies.
func (p Policy) ProviderBudgetFits(snap *Snapshot, reqPromptTokens, reqMaxTokens int) (fits, known bool) {
	budget, known := p.LiveRemainingBudget(snap)
	if !known {
		return true, false
	}
	return budget >= 0 && RequestTokens(reqPromptTokens, reqMaxTokens) <= uint64(budget), true
}

// RequestTokens shares the request-size normalization used by live
// provider fit and structural fleet prediction. Two nonnegative int values fit
// in uint64 even when their sum cannot be represented by int, so an enormous
// request cannot wrap below a known budget or context ceiling.
func RequestTokens(prompt, output int) uint64 {
	if output <= 0 {
		output = DefaultRequestedMaxTokens
	}
	return uint64(max(prompt, 0)) + uint64(output)
}
