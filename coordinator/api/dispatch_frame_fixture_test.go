package api

import (
	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// These helpers supply the dispatch collaborator's already-decided facts to
// real provider-frame handlers. Dispatch's producer tests separately exercise
// classification, loser selection and cleanup; these API fixtures pin the two
// possible frame/publication orders through the actual shared claim operation.
func publishSpeculativeLoserForFrameTest(srv *Server, pr *registry.PendingRequest) {
	pr.UsedBackup.Store(true)
	dispatchObserver{server: srv}.PendingOutcome(pr, attempt.SpeculativeLoserOutcome(pr))
}

func publishUnsentFailureForFrameTest(ap *registry.AttemptProfile) {
	ap.SetOutcome("error", "provider_error", "", "not_dispatched", "")
	ap.CompleteTerminal()
}

func releaseRejectedEmptyForFrameTest(srv *Server, provider *registry.Provider, pr *registry.PendingRequest) {
	pr.ResolveSpeculativeEmptyCompletion(false)
	provider.RemovePending(pr.RequestID)
	srv.registry.SetProviderIdle(provider.ID)
}
