package payouts_test

import (
	"context"
	"log/slog"

	production "github.com/eigeninference/d-inference/coordinator/api/billing/payouts"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/billing/payoutrecovery"
)

type payoutFixture struct {
	*production.Owner
	billing *billing.Service
	logger  *slog.Logger
}

func (f *payoutFixture) SetService(service *billing.Service) {
	f.billing = service
	f.Owner.SetService(service)
}

func (f *payoutFixture) syncGlobalPayout(ctx context.Context, id string) error {
	return payoutrecovery.New(f.billing, f.logger).SyncGlobalPayout(ctx, id)
}

func (f *payoutFixture) sweepStuckStripeWithdrawals() {
	payoutrecovery.New(f.billing, f.logger).SweepStuckStripeWithdrawals()
}
