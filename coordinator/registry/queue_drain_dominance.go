package registry

// Per-pass dominance skip for the queue drain (drainQueuedRequestsForModels).
//
// A drain pass pops every fresh queued request for a model and asks the
// scheduler for a provider. Within one pass the fleet state only loses
// capacity (an admission removes it; a trigger that frees capacity mid-pass
// does not run its own pass but makes this one rerun with fresh records —
// queue_drain_coalesce.go), so once a request has been rejected purely on
// capacity/TTFT, any later request in the same pass that is at least as
// demanding — same structural eligibility, no smaller prompt or output
// budget, no looser TTFT ceiling — would get the identical "no candidate"
// verdict from an identical full fleet scan (~1 ms / 2 MB at 1,300
// providers). Those requests are requeued without a scan.
// Anything not provably dominated — a different constraint shape, a strictly
// smaller request, a looser TTFT ceiling, a cache plan that could shorten
// prefill — is scanned exactly as before, so a small request behind a large
// rejected one is still admitted in the same pass.

// drainDominanceKey holds every PendingRequest field that changes which
// providers pass the structural routing gates in scanCandidatesLocked. Two
// comparable requests with equal keys see the same eligible provider set.
type drainDominanceKey struct {
	requiresVision bool
	traits         RequestTraits
}

// drainRejectionRecord is one pure capacity/TTFT rejection observed in the
// current drain pass for a model.
type drainRejectionRecord struct {
	key            drainDominanceKey
	promptTokens   int
	maxTokens      int
	maxTTFTMs      float64
	ttftRejections int
}

// drainDominanceComparable reports whether pr's eligible provider set is the
// plain public fleet for its model, so it can take part in dominance
// reasoning at all. Owner-scoped, serial-pinned, provider-excluding, and
// cache-planned requests are always scanned: their eligible sets (or prefill
// estimates) differ from a plain request's.
func drainDominanceComparable(pr *PendingRequest) bool {
	return pr != nil &&
		!pr.SelfRouteOnly && !pr.PreferOwner &&
		len(pr.AllowedProviderSerials) == 0 &&
		len(pr.ExcludedProviderIDs) == 0 &&
		!pr.CachePlan.present()
}

// drainPureCapacityRejection reports whether a failed reservation was decided
// solely by transient gates: no candidate passed, and at least one provider
// was rejected only for capacity or only for the per-request TTFT ceiling.
// Deterministic failures (tool-constraint, TTFT-terminal) are handled before
// this is consulted; a nil provider with CandidateCount > 0 is the commit
// re-check race, not a fleet verdict.
func drainPureCapacityRejection(decision RoutingDecision) bool {
	return decision.CandidateCount == 0 &&
		(decision.CapacityRejections > 0 || decision.TTFTRejections > 0)
}

// drainRequestSize normalizes the admission-relevant request size exactly as
// reserveProvider and buildCandidateWithReason do.
func drainRequestSize(pr *PendingRequest) (prompt, maxTok int) {
	prompt = pr.EstimatedPromptTokens
	if prompt < 0 {
		prompt = 0
	}
	maxTok = pr.RequestedMaxTokens
	if maxTok <= 0 {
		maxTok = defaultRequestedMaxTokens
	}
	return prompt, maxTok
}

// drainRejectionRecordFor converts a failed reservation into a dominance
// record, or reports false when the request or verdict cannot anchor
// dominance reasoning.
func drainRejectionRecordFor(pr *PendingRequest, decision RoutingDecision) (drainRejectionRecord, bool) {
	if !drainDominanceComparable(pr) || !drainPureCapacityRejection(decision) {
		return drainRejectionRecord{}, false
	}
	prompt, maxTok := drainRequestSize(pr)
	return drainRejectionRecord{
		key:            drainDominanceKey{requiresVision: pr.RequiresVision, traits: pr.Traits},
		promptTokens:   prompt,
		maxTokens:      maxTok,
		maxTTFTMs:      pr.MaxTTFTMs,
		ttftRejections: decision.TTFTRejections,
	}, true
}

// ttftCeilingNoLooser reports whether a request with ceiling q cannot pass a
// TTFT gate that rejected a request with ceiling r (0 = no ceiling). A record
// only carries TTFT rejections when r > 0.
func ttftCeilingNoLooser(q, r float64) bool {
	return r <= 0 || (q > 0 && q <= r)
}

// drainDominated reports whether pr would receive the same pure capacity/TTFT
// rejection as a request already rejected in this pass, so its fleet scan can
// be skipped. Capacity admission (freeMemoryAdmits / pooledBudgetAdmits) is
// monotone in prompt+max tokens and the TTFT estimate is monotone in prompt
// tokens, so a request that is no smaller on both, with a ceiling no looser,
// fails every provider the record failed.
func drainDominated(pr *PendingRequest, rejected []drainRejectionRecord) bool {
	if len(rejected) == 0 || !drainDominanceComparable(pr) {
		return false
	}
	key := drainDominanceKey{requiresVision: pr.RequiresVision, traits: pr.Traits}
	prompt, maxTok := drainRequestSize(pr)
	for i := range rejected {
		rec := &rejected[i]
		if rec.key != key || prompt < rec.promptTokens || maxTok < rec.maxTokens {
			continue
		}
		if rec.ttftRejections > 0 && !ttftCeilingNoLooser(pr.MaxTTFTMs, rec.maxTTFTMs) {
			continue
		}
		return true
	}
	return false
}
