package attempt

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// PendingOutcomeObserver supplies publication effects after the terminal claim
// and profile transition. Calls occur without a request lock held.
type PendingOutcomeObserver interface {
	CacheTerminal(*registry.PendingRequest)
	RouteOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome)
}

// PublishPendingOutcome applies the shared claim/profile transition before
// cache and route publication. A successful commit leaves terminal profile
// completion to the provider; losing terminal claims publish nothing.
func PublishPendingOutcome(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome, observer PendingOutcomeObserver) {
	if pr == nil {
		return
	}
	terminal := outcome != nil && outcome.FinalStatus != ""
	if terminal {
		if !pr.MarkRouteOutcomeFinalized() {
			return
		}
		if ap := pr.Profile; ap != nil {
			ap.SetOutcome(outcome.FinalStatus, ProfileErrorReason(outcome), "", "", "")
			// Consumer-side synthetic terminals ARE the terminal half; a success
			// outcome is written at commit time and must wait for the provider's
			// terminal so the record carries settlement stamps and its profile.
			// A terminal already claimed by a provider frame is completed by
			// that frame once its provider outcome is written, so the record is
			// never built with an empty provider_outcome in between.
			if outcome.FinalStatus != FinalStatusSuccess {
				ap.CompleteTerminalUnlessClaimed()
			}
		}
		// Consumer-side synthetic terminals (notably registry.Disconnect's
		// ErrorCh delivery, local timeout, and grace expiry) do not pass through a
		// provider terminal handler. Close their cache-selection denominator as
		// unreported; the per-attempt claim makes this idempotent with provider
		// complete/error races.
		observer.CacheTerminal(pr)
	}
	observer.RouteOutcome(pr.RequestID, pr.Attempt, pr.Model, outcome)
}
