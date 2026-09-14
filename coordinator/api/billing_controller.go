package api

import (
	"context"

	billingapi "github.com/eigeninference/d-inference/coordinator/api/billing"
)

// billingController binds endpoint policy to the router's existing service
// lifecycle. The getters retain SetBilling/SetBaseRewards updates made after
// NewServer registered routes; inference and HTTP billing use the same services.
func (s *Server) billingController() *billingapi.Controller {
	return billingapi.New(billingapi.Dependencies{
		Store: s.store, Service: s.Billing, BaseRewards: s.BaseRewards,
		Logger: s.logger, Cache: s.readCache, Metrics: billingMetrics{s},
		AuthorizeAdmin: s.isAdminAuthorized,
	})
}

type billingMetrics struct{ server *Server }

func (m billingMetrics) Incr(name string, tags []string) { m.server.ddIncr(name, tags) }

// StartStripePayoutReconciler launches the existing stuck-withdrawal worker.
func (s *Server) StartStripePayoutReconciler(ctx context.Context) {
	s.billingController().StartStripePayoutReconciler(ctx)
}

// StartGlobalPayoutReconciler launches the existing quote cleanup and payout worker.
func (s *Server) StartGlobalPayoutReconciler(ctx context.Context) {
	s.billingController().StartGlobalPayoutReconciler(ctx)
}
