package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/queuedrain"

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

type drainRejectionRecord = queuedrain.Rejection[RequestTraits]

// QueueWorkload derives the exact monotone-drain cohort from request metadata.
// It contains no request body, owner identity or mutable provider capacity.
func (pr *PendingRequest) QueueWorkload() queuedrain.Work[RequestTraits] {
	if pr == nil {
		return queuedrain.Work[RequestTraits]{}
	}
	return queuedrain.Work[RequestTraits]{
		Comparable: !pr.SelfRouteOnly && !pr.PreferOwner && len(pr.AllowedProviderSerials) == 0 && len(pr.ExcludedProviderIDs) == 0 && !pr.CachePlan.Present(),
		Vision:     pr.RequiresVision, Traits: pr.Traits, PromptTokens: pr.EstimatedPromptTokens,
		MaxTokens: pr.RequestedMaxTokens, MaxTTFTMs: pr.MaxTTFTMs,
	}
}

func drainVerdict(decision RoutingDecision) queuedrain.Verdict {
	return queuedrain.Verdict{Candidates: decision.CandidateCount, CapacityRejections: decision.CapacityRejections, TTFTRejections: decision.TTFTRejections}
}
func drainPureCapacityRejection(decision RoutingDecision) bool {
	return queuedrain.PureCapacityRejection(drainVerdict(decision))
}
func drainRejectionRecordFor(pr *PendingRequest, decision RoutingDecision) (drainRejectionRecord, bool) {
	return queuedrain.RejectionFor(pr.QueueWorkload(), drainVerdict(decision))
}
func drainDominated(pr *PendingRequest, rejected []drainRejectionRecord) bool {
	return queuedrain.Dominated(pr.QueueWorkload(), rejected)
}
