package api

import "context"

// StartStripePayoutReconciler preserves the application lifecycle entry point;
// payout state and recovery execution belong to the payout owner.
func (s *Server) StartStripePayoutReconciler(ctx context.Context) {
	s.payouts.StartStripePayoutReconciler(ctx)
}

func (s *Server) StartGlobalPayoutReconciler(ctx context.Context) {
	s.payouts.StartGlobalPayoutReconciler(ctx)
}
