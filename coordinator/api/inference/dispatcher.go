package inference

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// NewDispatcher binds the same accounting, cancellation, routing and admission
// resources used by this request owner; it cannot become another settlement owner.
func (s *Owner) NewDispatcher() *dispatch.Dispatcher {
	return dispatch.New(dispatch.Dependencies{
		Registry: s.registry, Store: s.store, Observation: s.observation, Logger: s.logger,
		Reservations: s.reservations, Cancellation: s.cancels, Gate: s.scanGate, Backoff: s.backoff,
		Calibration: contextCalibration, CloseAttempt: closeUndispatchedAttempt,
		RecordPolicy: func(ap *registry.AttemptProfile, p dispatch.Scope, vision bool) {
			s.recordPredictivePolicy(ap, selfRoutePolicy{enabled: p.SelfRouteOnly, prefer: p.PreferOwner, ownerAccountID: p.OwnerAccountID}, vision)
		},
	}, dispatch.Config{BillingEnabled: s.billing != nil, HardTTFTReject: s.ttftHardReject, MinDecodeTPS: s.minDecodeTPS})
}

// dispatchExclusions adapts the owner's private exclusion set to the transport's
// selection contract. No mutable collection crosses the component boundary.
type dispatchExclusions map[string]struct{}

func (s dispatchExclusions) IDs() []string {
	ids := make([]string, 0, len(s))
	for id := range s {
		ids = append(ids, id)
	}
	return ids
}

func (s dispatchExclusions) Exclude(id string) { s[id] = struct{}{} }
