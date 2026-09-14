package api

import "github.com/eigeninference/d-inference/coordinator/inference/settlement"

// inferenceSettlement binds the existing ledger and hold map without copying
// their state. Store, provider and referral lookups keep their live bindings.
func (s *Server) inferenceSettlement() settlement.Service {
	return settlement.New(settlement.Dependencies{
		Store:     func() settlement.Store { return s.store },
		Ledger:    s.ledger,
		Providers: func() settlement.Providers { return s.registry },
		Referral: func() settlement.Referral {
			if s.billing == nil || s.billing.Referral() == nil {
				return nil
			}
			return s.billing.Referral()
		},
		Metrics:      inferenceMetrics{server: s},
		Logger:       s.logger,
		ServiceHolds: s.serviceReservations,
	})
}
