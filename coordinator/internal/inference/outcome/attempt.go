package outcome

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Attempt is immutable correlation evidence captured before a wait can clear
// or promote its provider/pending binding. It grants no mutable owner access.
type Attempt struct {
	provider  *registry.Provider
	pending   *registry.PendingRequest
	requestID string
	index     int
}

func CaptureAttempt(provider *registry.Provider, pending *registry.PendingRequest, requestID string, index int) Attempt {
	return Attempt{provider: provider, pending: pending, requestID: requestID, index: index}
}

func CurrentOrCaptured(captured Attempt, provider *registry.Provider, pending *registry.PendingRequest, requestID string, index int) Attempt {
	if pending == nil {
		// A cleared ID means the speculative sub-wait already recorded its own
		// terminal; restoring its captured primary would attribute it twice.
		if requestID == "" {
			return Attempt{}
		}
		return captured
	}
	if requestID == "" {
		requestID = pending.RequestID
	}
	return CaptureAttempt(provider, pending, requestID, index)
}

// RecordAfterWait retains the captured identity when a failed wait released its
// active binding, but never restores a speculative attempt already finalized.
func (a Attempt) RecordAfterWait(captured Attempt, r *Recorder, model string, build func(*registry.PendingRequest) *store.InferenceRouteOutcome) {
	CurrentOrCaptured(captured, a.provider, a.pending, a.requestID, a.index).Record(r, model, build)
}

// Record chooses the pending-aware one-shot terminal funnel only for an exact
// request/attempt/provider binding; mismatches keep the ordinary keyed write.
// The builder derives the outcome from the same captured pending observation.
func (a Attempt) Record(r *Recorder, model string, build func(*registry.PendingRequest) *store.InferenceRouteOutcome) {
	if a.requestID == "" {
		return
	}
	out := build(a.pending)
	providerMatches := a.provider == nil ||
		(a.pending != nil && a.pending.ProviderID != "" && a.pending.ProviderID == a.provider.ID)
	if a.pending != nil && a.pending.RequestID == a.requestID && a.pending.Attempt == a.index && providerMatches {
		r.Pending(a.pending, out)
		return
	}
	r.Update(a.requestID, a.index, model, out)
}
