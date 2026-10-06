package cachefunnel

// Record is the closed account of one request. It is delivered to the Sink
// and never retained by the Ledger.
type Record struct {
	Reason Reason
	// Planned: the body the request was to be dispatched with had a cache
	// plan. The request may still have ended before any dispatch.
	Planned bool
	// Attempts counts attempts handed to a provider, including retries and hedges.
	Attempts int
	// DispatchedWithoutScope: the classifying attempt went to a provider that
	// received no cache scope.
	DispatchedWithoutScope bool
	// LookupOutcomeReported: the completing provider reported a lookup outcome.
	LookupOutcomeReported bool
	// HitTier is the tier of the reported hit; TierNotReported for every
	// request that did not end in a hit.
	HitTier Tier
	// PromptTokens is the planner's count; ProviderPromptTokens is the
	// completing provider's.
	PromptTokens         Tokens
	RepeatedPrefixTokens Tokens
	PredictedTokens      Tokens
	ReusedTokens         Tokens
	PrefillSavedTokens   Tokens
	ProviderPromptTokens Tokens
}

// LateCompletion is what a completion that classified no request reported.
type LateCompletion struct {
	// HitTier is the tier of the reported hit; TierNotReported for every
	// completion that did not report one.
	HitTier            Tier
	ReusedTokens       Tokens
	PrefillSavedTokens Tokens
}

// Sink receives every closed record and every late completion exactly once.
// It is called without any funnel lock held and must not block.
type Sink interface {
	ObserveCacheFunnelRecord(Record)
	ObserveLateCacheFunnelCompletion(LateCompletion)
}
