package api

// Stripe payout reconciler — background safety net for withdrawals stuck in
// "transferred".
//
// A withdrawal sits in "transferred" between the platform→connected-account
// transfer and Stripe's automatic payout sweep reaching the user's bank
// (normally < ~2 days). Rows stuck longer than that indicate a problem, the
// most common being connected accounts created by older code with a "manual"
// payout schedule: Stripe never sweeps those, the money sits in the connected
// balance forever, and the user's Stripe dashboard shows "Contact Eigen Labs,
// Inc. to get paid out or to update your payout schedule."
//
// Every sweep the reconciler:
//  1. lists withdrawals stuck in "transferred" for longer than the threshold,
//  2. for each affected connected account, flips a legacy "manual" payout
//     schedule to automatic daily (idempotent) so the parked balance drains
//     to the user's bank on the next sweep,
//  3. logs a loud per-account summary for ops.
//
// It never touches the ledger — money movement stays in the withdraw handler
// and the webhook state machine.

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

const (
	// stripeReconcileInterval is how often the reconciler sweeps.
	stripeReconcileInterval = 1 * time.Hour

	// stripeStuckThreshold is how long a withdrawal may sit in "transferred"
	// before it is considered stuck. The normal happy path is: transfer →
	// (up to 24h availability delay on recipient accounts) → daily sweep →
	// bank rail. 48h covers all of that with margin.
	stripeStuckThreshold = 48 * time.Hour

	// stripeReconcileBatch bounds how many stuck rows one sweep inspects.
	stripeReconcileBatch = 200
)

// StartStripePayoutReconciler launches the hourly stuck-withdrawal sweep.
// No-op when Stripe Connect isn't configured.
func (s *Server) StartStripePayoutReconciler(ctx context.Context) {
	if s.billing == nil || s.billing.StripeConnect() == nil {
		return
	}
	s.logger.Info("stripe payout reconciler started",
		"interval", stripeReconcileInterval.String(),
		"stuck_threshold", stripeStuckThreshold.String())
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
		ticker := time.NewTicker(stripeReconcileInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.sweepStuckStripeWithdrawals()
			}
		}
	})
}

// sweepStuckStripeWithdrawals runs one reconciler pass.
func (s *Server) sweepStuckStripeWithdrawals() {
	cutoff := time.Now().Add(-stripeStuckThreshold)
	stuck, err := s.billing.Store().ListStripeWithdrawalsByStatus("transferred", cutoff, stripeReconcileBatch)
	if err != nil {
		s.logger.Error("stripe reconciler: list stuck withdrawals failed", "error", err)
		return
	}
	if len(stuck) == 0 {
		return
	}

	// Group by connected account — one Stripe lookup (and at most one
	// schedule heal) per account, not per withdrawal.
	byAcct := map[string]int{}
	for _, wd := range stuck {
		byAcct[wd.StripeAccountID]++
	}
	s.logger.Warn("stripe reconciler: withdrawals stuck in transferred",
		"withdrawals", len(stuck), "accounts", len(byAcct), "stuck_threshold", stripeStuckThreshold.String())

	for acctID, count := range byAcct {
		if acctID == "" {
			continue
		}
		acct, err := s.billing.StripeConnect().GetAccount(acctID)
		if err != nil {
			s.logger.Warn("stripe reconciler: account fetch failed",
				"stripe_account_id", acctID, "stuck_withdrawals", count, "error", err)
			continue
		}
		if acct.PayoutInterval == "manual" {
			if err := s.billing.StripeConnect().UpdateAccountPayoutScheduleDaily(acctID); err != nil {
				s.logger.Error("stripe reconciler: payout schedule heal failed",
					"stripe_account_id", acctID, "stuck_withdrawals", count, "error", err)
				continue
			}
			s.logger.Info("stripe reconciler: healed manual payout schedule to daily",
				"stripe_account_id", acctID, "stuck_withdrawals", count)
			continue
		}
		// Schedule is already automatic — the sweep should be moving these.
		// Loud log for ops: likely payouts_enabled=false (user needs to fix
		// bank details) or a failed sweep that keeps retrying.
		s.logger.Warn("stripe reconciler: stuck withdrawals on auto-schedule account",
			"stripe_account_id", acctID, "stuck_withdrawals", count,
			"payouts_enabled", acct.PayoutsEnabled,
			"disabled_reason", acct.DisabledReason,
			"payout_interval", acct.PayoutInterval)
	}
}
