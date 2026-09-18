package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// trialServedByOwner follows the serving object across deregistration. Trial
// routing preference alone is not proof of ownership or eligibility for free
// owned-machine service.
func trialServedByOwner(pr *registry.PendingRequest, provider *registry.Provider) bool {
	if pr == nil || provider == nil || (!pr.FreeSelfRoute && !pr.PreferOwner) {
		return false
	}
	provider.Mu().Lock()
	owner := provider.AccountID
	provider.Mu().Unlock()
	return owner != "" && owner == pr.ConsumerKey
}

// AttemptUsage on inference_error remains observation-only. Only a validated
// inference_complete can authorize a subsidy and provider payment. Error
// terminals with any observed content retain their hold for reconciliation.
func (s *Server) handleBonsaiTrialError(pr *registry.PendingRequest, provider *registry.Provider, msg *protocol.InferenceErrorMessage, providerTerminal bool) {
	if pr == nil || pr.TrialReservation == nil {
		return
	}
	if trialServedByOwner(pr, provider) {
		s.settleBonsaiTrial(pr, provider, protocol.UsageInfo{}, true)
		return
	}
	if providerTerminal && msg != nil && msg.CoordinatorCause == "" && !pr.HasFirstContentIngress() && !pr.ContentCommittedSafe() {
		if proof := pr.TrialUnusedConfirmed; proof != nil {
			proof.Store(true)
		}
		return
	}
	s.releaseTrialReservation(pr.TrialReservation, false)
}
