package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// FirstContentDeadlineForIdentity selects only the token term for this actual
// renderer. Both cutoffs are absolute; missing identity never borrows another
// provider's count, and no selection/retry starts a new clock.
func (pr *PendingRequest) FirstContentDeadlineForIdentity(artifact, contract string) time.Time {
	if pr == nil {
		return time.Time{}
	}
	if pr.firstContentDeadlineBound || pr.FirstContentFallbackDeadline.IsZero() {
		return pr.FirstContentDeadline
	}
	if !pr.FirstContentQualifiedDeadline.IsZero() && pr.PromptWork != nil &&
		pr.PromptWork.Source == protocol.PromptWorkExact && pr.PromptWork.IsQualifiedFor(artifact, contract) {
		return pr.FirstContentQualifiedDeadline
	}
	return pr.FirstContentFallbackDeadline
}

// FirstContentDeadlineEnvelope bounds planning, queueing and unselected scans
// without discarding a qualifying provider when only the heuristic clock has
// expired. It never authorizes a provider to use this larger budget.
func (pr *PendingRequest) FirstContentDeadlineEnvelope() time.Time {
	if pr == nil {
		return time.Time{}
	}
	if pr.firstContentDeadlineBound || pr.FirstContentFallbackDeadline.IsZero() {
		return pr.FirstContentDeadline
	}
	if pr.FirstContentQualifiedDeadline.After(pr.FirstContentFallbackDeadline) {
		return pr.FirstContentQualifiedDeadline
	}
	return pr.FirstContentFallbackDeadline
}

func candidateFirstContentDeadline(c *routingCandidate, pr *PendingRequest) time.Time {
	return pr.FirstContentDeadlineForIdentity(c.snapshot.promptWorkArtifactHash, c.snapshot.promptWorkContractID)
}
