package protocol

// DeadlinePerformanceProfileReference identifies reviewed first-content cells
// for the exact constructed scheduler. It grants no concurrency or chunk-policy
// authority; PerformanceProfile remains the separate serving qualification.
type DeadlinePerformanceProfileReference struct {
	ID                           string              `json:"id"`
	RuntimeRevision              string              `json:"runtime_revision"`
	ConfiguredContextTokens      int                 `json:"configured_context_tokens"`
	EffectiveMaxConcurrency      int                 `json:"effective_max_concurrency"`
	PrefillChunkSize             int                 `json:"prefill_chunk_size"`
	SoloPrefillStripeTokens      *int                `json:"solo_prefill_stripe_tokens,omitempty"`
	MaxConcurrentPartialPrefills int                 `json:"max_concurrent_partial_prefills"`
	MixedPrefillTokenCap         *int                `json:"mixed_prefill_token_cap,omitempty"`
	MTP                          *ServingMTPIdentity `json:"mtp,omitempty"`
}

func (p *DeadlinePerformanceProfileReference) Clone() *DeadlinePerformanceProfileReference {
	if p == nil {
		return nil
	}
	out := *p
	out.MixedPrefillTokenCap = clonePtr(p.MixedPrefillTokenCap)
	out.SoloPrefillStripeTokens = clonePtr(p.SoloPrefillStripeTokens)
	out.MTP = p.MTP.Clone()
	return &out
}
