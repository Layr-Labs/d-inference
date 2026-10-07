package payouts

import (
	"context"
	"time"

	payoutrecovery "github.com/eigeninference/d-inference/coordinator/internal/billing/payoutrecovery"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// StartStripePayoutReconciler launches the hourly stuck-withdrawal sweep: it
// heals legacy "manual" payout schedules (which strand transferred funds in
// the connected balance forever) and alerts on rows that stay non-terminal
// past the threshold. Confirmed transfer rejections also retry their atomic ledger refunds.
// Historical unverified failures are left for operator reconciliation.
func (s *Owner) StartStripePayoutReconciler(ctx context.Context) {
	if s.billing == nil {
		return
	}
	s.logger.Info("stripe payout reconciler started",
		"interval", payoutrecovery.StripeReconcileInterval.String(),
		"stuck_threshold", payoutrecovery.StripeStuckThreshold.String())
	saferun.Go(s.logger, "api.stripePayoutReconciler", func() {
		// First sweep shortly after boot so a deploy heals stuck accounts
		// without waiting an hour.
		timer := time.NewTimer(1 * time.Minute)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			s.sweepStuckStripeWithdrawals()
		}
		ticker := time.NewTicker(payoutrecovery.StripeReconcileInterval)
		defer ticker.Stop()
		refundTicker := time.NewTicker(time.Minute)
		defer refundTicker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.sweepStuckStripeWithdrawals()
			case <-refundTicker.C:
				s.recoverStripeRefunds()
			}
		}
	})
}
