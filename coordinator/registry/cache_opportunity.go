package registry

// CacheOpportunity is numeric, low-cardinality diagnostics for one routing
// evaluation. RepeatedPrefixTokens is observed demand, not saved work or proof
// that any machine holds the prefix. Holder counts are providers, not requests.
type CacheOpportunity struct {
	AffinityApplied      bool
	Evaluated            bool
	RepeatedPrefixTokens int
	MatchingHolders      int
	ValidHolders         int
	UsableCandidates     int
	CreditedCandidates   int
}

// CacheOpportunityReason describes the most recent reservation evaluation.
// It is emitted once by the existing terminal claim, so retries/rescans cannot
// multiply the terminal count. Receipt rejection metrics explain invalidations
// independently; absence of a holder does not establish why it disappeared.
func (pr *PendingRequest) CacheOpportunityReason() string {
	if pr == nil || !pr.CacheOpportunity.Evaluated {
		return "not_evaluated"
	}
	if pr.CacheSelectionSelected {
		return "selected"
	}
	o := pr.CacheOpportunity
	if o.MatchingHolders == 0 {
		if o.RepeatedPrefixTokens == 0 {
			return "no_repeat_observed"
		}
		return "repeat_without_holder"
	}
	if o.ValidHolders == 0 {
		return "holder_evidence_unusable"
	}
	if o.UsableCandidates == 0 {
		return "holder_unavailable"
	}
	if o.CreditedCandidates == 0 {
		return "holder_no_positive_credit"
	}
	return "holder_not_selected"
}
