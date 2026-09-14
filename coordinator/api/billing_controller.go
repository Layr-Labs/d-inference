package api

import (
	"context"

	billingapi "github.com/eigeninference/d-inference/coordinator/api/billing"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
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

// SetBilling configures the billing service for multi-chain payments and referrals.
func (s *Server) SetBilling(svc *billing.Service) {
	s.billing = svc
}

func (s *Server) Billing() *billing.Service {
	return s.billing
}

// SetBaseRewards configures the provider base-rewards engine (off unless the
// EIGENINFERENCE_BASE_REWARDS flag is set; nil = disabled).
func (s *Server) SetBaseRewards(e *baserewards.Engine) {
	s.baseRewards = e
}

// BaseRewards returns the base-rewards engine, or nil when disabled.
func (s *Server) BaseRewards() *baserewards.Engine {
	return s.baseRewards
}
