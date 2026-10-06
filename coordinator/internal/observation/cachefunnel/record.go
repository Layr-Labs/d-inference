package cachefunnel

// Record is the closed account of one request. It is delivered to the Sink
// and never retained by the Ledger.
type Record struct {
	Reason Reason
	// Attempts counts attempts handed to a provider, including retries and hedges.
	Attempts int
	// DispatchedWithoutScope: the classifying attempt went to a provider that
	// received no cache scope.
	DispatchedWithoutScope bool
	// LookupOutcomeReported: the completing provider reported a lookup outcome.
	LookupOutcomeReported bool
	PromptTokens          Tokens
	RepeatedPrefixTokens  Tokens
	PredictedTokens       Tokens
	ReusedTokens          Tokens
}

// Sink receives every closed record exactly once. It is called without any
// funnel lock held and must not block.
type Sink interface {
	ObserveCacheFunnelRecord(Record)
}
