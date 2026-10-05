package payouts

import (
	"context"

	payoutrecovery "github.com/eigeninference/d-inference/coordinator/internal/billing/payoutrecovery"
)

func (s *Owner) syncGlobalPayout(ctx context.Context, id string) error {
	return payoutrecovery.New(s.billing, s.logger).SyncGlobalPayout(ctx, id)
}

func (s *Owner) sweepStuckStripeWithdrawals() {
	payoutrecovery.New(s.billing, s.logger).SweepStuckStripeWithdrawals()
}

func (s *Owner) recoverStripeRefunds() {
	payoutrecovery.New(s.billing, s.logger).RecoverStripeRefunds()
}
