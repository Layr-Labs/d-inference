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
		Metrics:      settlementMetrics{server: s},
		Logger:       s.logger,
		ServiceHolds: s.serviceReservations,
	})
}

type settlementMetrics struct{ server *Server }

func (m settlementMetrics) Incr(name string, tags []string) { m.server.ddIncr(name, tags) }
func (m settlementMetrics) Count(name string, value int64, tags []string) {
	m.server.ddCount(name, value, tags)
}
func (m settlementMetrics) Histogram(name string, value float64, tags []string) {
	m.server.ddHistogram(name, value, tags)
}
