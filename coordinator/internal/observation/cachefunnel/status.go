package cachefunnel

// Status is the aggregate funnel. Entered = Closed + InFlight, and Closed is
// the sum of Requests over Reasons, which Total repeats for convenience.
type Status struct {
	Entered    uint64            `json:"entered"`
	Closed     uint64            `json:"closed"`
	InFlight   uint64            `json:"in_flight"`
	Total      Totals            `json:"total"`
	Reasons    []ReasonTotals    `json:"reasons"`
	Late       LateEvidence      `json:"late"`
	Unobserved []UnobservedStage `json:"unobserved"`
}

// LateEvidence counts evidence that arrived too late to be part of its
// request's record. It changed no reason and no total, so it is counted here
// and nowhere else. It holds counts only and is copied whole into the public
// status: a token sum must never be added to it (the Sink carries those).
type LateEvidence struct {
	// Completions: a provider completion that classified no request, because
	// the request had closed (its client left) or a hedged twin had completed
	// first. It is still billed and still feeds the per-completion usage
	// counters, which is why they can exceed the funnel's.
	Completions uint64 `json:"completions"`
	// MemoryHitCompletions and SSDHitCompletions are the late completions that
	// reported a hit, by tier: the hits the per-completion counters hold and
	// MemoryHitRequests and SSDHitRequests do not.
	MemoryHitCompletions uint64 `json:"memory_hit_completions"`
	SSDHitCompletions    uint64 `json:"ssd_hit_completions"`
	// AttemptDispatches: attempts handed to a provider that Attempts missed.
	// One that was its request's first leaves that request out of Dispatched.
	AttemptDispatches uint64 `json:"attempt_dispatches"`
}

type ReasonTotals struct {
	Reason string `json:"reason"`
	Totals
}

// Totals sums closed records. Each "*_unknown" field counts the requests
// whose quantity was not observed; those requests add nothing to the sum.
type Totals struct {
	Requests uint64 `json:"requests"`
	// Planned counts requests whose dispatch body had a cache plan, whether or
	// not they reached a provider; Dispatched counts requests handed to a
	// provider at least once. Neither is a subset of the other.
	Planned                uint64 `json:"planned"`
	Dispatched             uint64 `json:"dispatched"`
	Attempts               uint64 `json:"attempts"`
	DispatchedWithoutScope uint64 `json:"dispatched_without_scope"`
	LookupOutcomeReported  uint64 `json:"lookup_outcome_reported"`
	// MemoryHitRequests and SSDHitRequests split the requests that ended in a
	// reported hit by the tier it was restored from. A hit that names no tier
	// is in neither; validated provider usage never produces one.
	MemoryHitRequests           uint64 `json:"memory_hit_requests"`
	SSDHitRequests              uint64 `json:"ssd_hit_requests"`
	PromptTokens                uint64 `json:"prompt_tokens"`
	PromptTokensUnknown         uint64 `json:"prompt_tokens_unknown"`
	RepeatedPrefixTokens        uint64 `json:"repeated_prefix_tokens"`
	RepeatedPrefixTokensUnknown uint64 `json:"repeated_prefix_tokens_unknown"`
	PredictedTokens             uint64 `json:"predicted_tokens"`
	PredictedTokensUnknown      uint64 `json:"predicted_tokens_unknown"`
	ReusedTokens                uint64 `json:"reused_tokens"`
	ReusedTokensUnknown         uint64 `json:"reused_tokens_unknown"`
	PrefillSavedTokens          uint64 `json:"prefill_saved_tokens"`
	PrefillSavedTokensUnknown   uint64 `json:"prefill_saved_tokens_unknown"`
	ProviderPromptTokens        uint64 `json:"provider_prompt_tokens"`
	ProviderPromptTokensUnknown uint64 `json:"provider_prompt_tokens_unknown"`
}

// UnobservedStage names a lifecycle stage the coordinator does not feed into
// the funnel, so its quantities are reported as unknown rather than zero.
type UnobservedStage struct {
	Stage  string `json:"stage"`
	Reason string `json:"reason"`
}

func unobservedStages() []UnobservedStage {
	return []UnobservedStage{
		{Stage: "lookup_receipt", Reason: "the provider's lookup receipt message is not joined to the request; the lookup outcome comes from the completing usage report only"},
	}
}

func (t *Totals) add(record Record) {
	t.Requests++
	if record.Planned {
		t.Planned++
	}
	if record.Attempts > 0 {
		t.Dispatched++
	}
	t.Attempts += uint64(record.Attempts)
	if record.DispatchedWithoutScope {
		t.DispatchedWithoutScope++
	}
	if record.LookupOutcomeReported {
		t.LookupOutcomeReported++
	}
	switch record.HitTier {
	case TierMemory:
		t.MemoryHitRequests++
	case TierSSD:
		t.SSDHitRequests++
	}
	addTokens(&t.PromptTokens, &t.PromptTokensUnknown, record.PromptTokens)
	addTokens(&t.RepeatedPrefixTokens, &t.RepeatedPrefixTokensUnknown, record.RepeatedPrefixTokens)
	addTokens(&t.PredictedTokens, &t.PredictedTokensUnknown, record.PredictedTokens)
	addTokens(&t.ReusedTokens, &t.ReusedTokensUnknown, record.ReusedTokens)
	addTokens(&t.PrefillSavedTokens, &t.PrefillSavedTokensUnknown, record.PrefillSavedTokens)
	addTokens(&t.ProviderPromptTokens, &t.ProviderPromptTokensUnknown, record.ProviderPromptTokens)
}

func addTokens(sum, unknown *uint64, tokens Tokens) {
	if !tokens.Known {
		*unknown++
		return
	}
	*sum += uint64(tokens.Count)
}

func (t *Totals) merge(other Totals) {
	t.Requests += other.Requests
	t.Planned += other.Planned
	t.Dispatched += other.Dispatched
	t.Attempts += other.Attempts
	t.DispatchedWithoutScope += other.DispatchedWithoutScope
	t.LookupOutcomeReported += other.LookupOutcomeReported
	t.MemoryHitRequests += other.MemoryHitRequests
	t.SSDHitRequests += other.SSDHitRequests
	t.PromptTokens += other.PromptTokens
	t.PromptTokensUnknown += other.PromptTokensUnknown
	t.RepeatedPrefixTokens += other.RepeatedPrefixTokens
	t.RepeatedPrefixTokensUnknown += other.RepeatedPrefixTokensUnknown
	t.PredictedTokens += other.PredictedTokens
	t.PredictedTokensUnknown += other.PredictedTokensUnknown
	t.ReusedTokens += other.ReusedTokens
	t.ReusedTokensUnknown += other.ReusedTokensUnknown
	t.PrefillSavedTokens += other.PrefillSavedTokens
	t.PrefillSavedTokensUnknown += other.PrefillSavedTokensUnknown
	t.ProviderPromptTokens += other.ProviderPromptTokens
	t.ProviderPromptTokensUnknown += other.ProviderPromptTokensUnknown
}

// PublicStatus is the funnel as an unauthenticated reader may see it: counts
// of requests only. Token sums are left out because the difference between two
// snapshots around a single closing request is that request's exact
// prompt-derived token counts.
type PublicStatus struct {
	Entered    uint64               `json:"entered"`
	Closed     uint64               `json:"closed"`
	InFlight   uint64               `json:"in_flight"`
	Total      PublicTotals         `json:"total"`
	Reasons    []PublicReasonTotals `json:"reasons"`
	Late       LateEvidence         `json:"late"`
	Unobserved []UnobservedStage    `json:"unobserved"`
}

type PublicReasonTotals struct {
	Reason string `json:"reason"`
	PublicTotals
}

// PublicTotals keeps every counter of Totals that counts requests or attempts.
type PublicTotals struct {
	Requests                    uint64 `json:"requests"`
	Planned                     uint64 `json:"planned"`
	Dispatched                  uint64 `json:"dispatched"`
	Attempts                    uint64 `json:"attempts"`
	DispatchedWithoutScope      uint64 `json:"dispatched_without_scope"`
	LookupOutcomeReported       uint64 `json:"lookup_outcome_reported"`
	MemoryHitRequests           uint64 `json:"memory_hit_requests"`
	SSDHitRequests              uint64 `json:"ssd_hit_requests"`
	PromptTokensUnknown         uint64 `json:"prompt_tokens_unknown"`
	RepeatedPrefixTokensUnknown uint64 `json:"repeated_prefix_tokens_unknown"`
	PredictedTokensUnknown      uint64 `json:"predicted_tokens_unknown"`
	ReusedTokensUnknown         uint64 `json:"reused_tokens_unknown"`
	PrefillSavedTokensUnknown   uint64 `json:"prefill_saved_tokens_unknown"`
	ProviderPromptTokensUnknown uint64 `json:"provider_prompt_tokens_unknown"`
}

// Public drops every token sum.
func (s Status) Public() PublicStatus {
	public := PublicStatus{
		Entered: s.Entered, Closed: s.Closed, InFlight: s.InFlight,
		Total:      s.Total.public(),
		Reasons:    make([]PublicReasonTotals, len(s.Reasons)),
		Late:       s.Late,
		Unobserved: s.Unobserved,
	}
	for i, reason := range s.Reasons {
		public.Reasons[i] = PublicReasonTotals{Reason: reason.Reason, PublicTotals: reason.Totals.public()}
	}
	return public
}

func (t Totals) public() PublicTotals {
	return PublicTotals{
		Requests: t.Requests, Planned: t.Planned, Dispatched: t.Dispatched, Attempts: t.Attempts,
		DispatchedWithoutScope: t.DispatchedWithoutScope, LookupOutcomeReported: t.LookupOutcomeReported,
		MemoryHitRequests: t.MemoryHitRequests, SSDHitRequests: t.SSDHitRequests,
		PromptTokensUnknown: t.PromptTokensUnknown, RepeatedPrefixTokensUnknown: t.RepeatedPrefixTokensUnknown,
		PredictedTokensUnknown: t.PredictedTokensUnknown, ReusedTokensUnknown: t.ReusedTokensUnknown,
		PrefillSavedTokensUnknown: t.PrefillSavedTokensUnknown, ProviderPromptTokensUnknown: t.ProviderPromptTokensUnknown,
	}
}
