package cachefunnel

// Status is the aggregate funnel. Entered = Closed + InFlight, and Closed is
// the sum of Requests over Reasons, which Total repeats for convenience.
type Status struct {
	Entered    uint64            `json:"entered"`
	Closed     uint64            `json:"closed"`
	InFlight   uint64            `json:"in_flight"`
	Total      Totals            `json:"total"`
	Reasons    []ReasonTotals    `json:"reasons"`
	Unobserved []UnobservedStage `json:"unobserved"`
}

type ReasonTotals struct {
	Reason string `json:"reason"`
	Totals
}

// Totals sums closed records. Each "*_unknown" field counts the requests
// whose quantity was not observed; those requests add nothing to the sum.
type Totals struct {
	Requests                    uint64 `json:"requests"`
	Attempts                    uint64 `json:"attempts"`
	DispatchedWithoutScope      uint64 `json:"dispatched_without_scope"`
	LookupOutcomeReported       uint64 `json:"lookup_outcome_reported"`
	PromptTokens                uint64 `json:"prompt_tokens"`
	PromptTokensUnknown         uint64 `json:"prompt_tokens_unknown"`
	RepeatedPrefixTokens        uint64 `json:"repeated_prefix_tokens"`
	RepeatedPrefixTokensUnknown uint64 `json:"repeated_prefix_tokens_unknown"`
	PredictedTokens             uint64 `json:"predicted_tokens"`
	PredictedTokensUnknown      uint64 `json:"predicted_tokens_unknown"`
	ReusedTokens                uint64 `json:"reused_tokens"`
	ReusedTokensUnknown         uint64 `json:"reused_tokens_unknown"`
}

// UnobservedStage names a lifecycle stage the coordinator does not feed into
// the funnel, so its quantities are reported as unknown rather than zero.
type UnobservedStage struct {
	Stage  string `json:"stage"`
	Reason string `json:"reason"`
}

func unobservedStages() []UnobservedStage {
	return []UnobservedStage{
		{Stage: "predicted_tokens", Reason: "the credited holder's anchor is not carried from provider selection to the request record"},
		{Stage: "lookup_receipt", Reason: "the provider's lookup receipt message is not joined to the request; the lookup outcome comes from the completing usage report only"},
	}
}

func (t *Totals) add(record Record) {
	t.Requests++
	t.Attempts += uint64(record.Attempts)
	if record.DispatchedWithoutScope {
		t.DispatchedWithoutScope++
	}
	if record.LookupOutcomeReported {
		t.LookupOutcomeReported++
	}
	addTokens(&t.PromptTokens, &t.PromptTokensUnknown, record.PromptTokens)
	addTokens(&t.RepeatedPrefixTokens, &t.RepeatedPrefixTokensUnknown, record.RepeatedPrefixTokens)
	addTokens(&t.PredictedTokens, &t.PredictedTokensUnknown, record.PredictedTokens)
	addTokens(&t.ReusedTokens, &t.ReusedTokensUnknown, record.ReusedTokens)
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
	t.Attempts += other.Attempts
	t.DispatchedWithoutScope += other.DispatchedWithoutScope
	t.LookupOutcomeReported += other.LookupOutcomeReported
	t.PromptTokens += other.PromptTokens
	t.PromptTokensUnknown += other.PromptTokensUnknown
	t.RepeatedPrefixTokens += other.RepeatedPrefixTokens
	t.RepeatedPrefixTokensUnknown += other.RepeatedPrefixTokensUnknown
	t.PredictedTokens += other.PredictedTokens
	t.PredictedTokensUnknown += other.PredictedTokensUnknown
	t.ReusedTokens += other.ReusedTokens
	t.ReusedTokensUnknown += other.ReusedTokensUnknown
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
	Unobserved []UnobservedStage    `json:"unobserved"`
}

type PublicReasonTotals struct {
	Reason string `json:"reason"`
	PublicTotals
}

// PublicTotals keeps every counter of Totals that counts requests or attempts.
type PublicTotals struct {
	Requests                    uint64 `json:"requests"`
	Attempts                    uint64 `json:"attempts"`
	DispatchedWithoutScope      uint64 `json:"dispatched_without_scope"`
	LookupOutcomeReported       uint64 `json:"lookup_outcome_reported"`
	PromptTokensUnknown         uint64 `json:"prompt_tokens_unknown"`
	RepeatedPrefixTokensUnknown uint64 `json:"repeated_prefix_tokens_unknown"`
	PredictedTokensUnknown      uint64 `json:"predicted_tokens_unknown"`
	ReusedTokensUnknown         uint64 `json:"reused_tokens_unknown"`
}

// Public drops every token sum.
func (s Status) Public() PublicStatus {
	public := PublicStatus{
		Entered: s.Entered, Closed: s.Closed, InFlight: s.InFlight,
		Total:      s.Total.public(),
		Reasons:    make([]PublicReasonTotals, len(s.Reasons)),
		Unobserved: s.Unobserved,
	}
	for i, reason := range s.Reasons {
		public.Reasons[i] = PublicReasonTotals{Reason: reason.Reason, PublicTotals: reason.Totals.public()}
	}
	return public
}

func (t Totals) public() PublicTotals {
	return PublicTotals{
		Requests: t.Requests, Attempts: t.Attempts,
		DispatchedWithoutScope: t.DispatchedWithoutScope, LookupOutcomeReported: t.LookupOutcomeReported,
		PromptTokensUnknown: t.PromptTokensUnknown, RepeatedPrefixTokensUnknown: t.RepeatedPrefixTokensUnknown,
		PredictedTokensUnknown: t.PredictedTokensUnknown, ReusedTokensUnknown: t.ReusedTokensUnknown,
	}
}
