// Package profile owns dispatch-side request profile stamps. Provider terminal
// ownership remains with the request's AttemptProfile and inference owner.
package profile

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func StampFirstContent(rp *registry.RequestProfile, pr *registry.PendingRequest, heldChunks int) {
	ap := pr.Profile
	if ap == nil {
		return
	}
	ap.Mark(registry.StampFirstChunkDequeued)
	ap.Mark(registry.StampFirstContent)
	if t := pr.FirstContentIngressAtSafe(); !t.IsZero() {
		ap.MarkAt(registry.StampFirstContentIngress, t)
	}
	rp.SetHeldPreambleChunks(heldChunks)
}

func StampCommitted(rp *registry.RequestProfile, pr *registry.PendingRequest, stream bool) {
	if rp != nil && stream {
		rp.Stamp(&rp.HeadersWrittenUS)
	}
	if ap := pr.Profile; ap != nil {
		ap.Winning.Store(true)
	}
}

// Finalize completes only the handler half. Provider terminals, synthetic
// terminals and grace expiry independently own the terminal half.
func Finalize(rp *registry.RequestProfile, r *http.Request, committed bool) {
	if rp == nil {
		return
	}
	clientOutcome := "completed"
	switch {
	case r != nil && r.Context().Err() != nil:
		rp.Stamp(&rp.ClientGoneUS)
		clientOutcome = "client_gone"
	case !committed:
		clientOutcome = "error_response"
	}
	for _, ap := range rp.Attempts() {
		ap.SetOutcome("", "", "", "", clientOutcome)
		ap.CompleteHandler()
	}
}

func StampClientGone(rp *registry.RequestProfile, phase string) {
	if rp == nil {
		return
	}
	rp.Stamp(&rp.ClientGoneUS)
	rp.SetClientGonePhase(phase)
}
