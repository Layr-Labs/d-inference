package api

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

	// stripeStuckThresholdWeekly is the equivalent bound for accounts on a
	// weekly automatic payout schedule (Japan — Stripe offers no daily
	// there): up to 7 days to the sweep, +24h availability, plus the bank
	// rail. Rows younger than this on a weekly account are in normal
	// transit, not stuck.
	stripeStuckThresholdWeekly = 10 * 24 * time.Hour

	// stripeReconcileBatch bounds how many stuck rows one sweep inspects.
	stripeReconcileBatch = 200
)

// StartStripePayoutReconciler launches the hourly stuck-withdrawal sweep: it
// heals legacy "manual" payout schedules (which strand transferred funds in
// the connected balance forever) and alerts on rows that stay non-terminal
// past the threshold. It never touches the ledger — money movement stays in
// the withdraw handler and the webhook state machine. No-op when Stripe
// Connect isn't configured.
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

	// Rows stuck in "pending" mean the transfer-create either never ran
	// (crash mid-request) or ran and the row update failed after retries —
	// in the latter case money moved without a local trace. No safe
	// automatic action exists (can't tell the two apart locally), so alert
	// for a manual check against the Stripe dashboard.
	if pending, err := s.billing.Store().ListStripeWithdrawalsByStatus("pending", cutoff, stripeReconcileBatch); err != nil {
		s.logger.Error("stripe reconciler: list stale pending withdrawals failed", "error", err)
	} else if len(pending) > 0 {
		for _, wd := range pending {
			s.logger.Error("stripe reconciler: withdrawal stuck in pending — verify against Stripe dashboard (idempotency key wd-tr-<id>)",
				"withdrawal_id", wd.ID, "account_id", wd.AccountID,
				"stripe_account_id", wd.StripeAccountID,
				"amount_micro_usd", wd.AmountMicroUSD, "created_at", wd.CreatedAt)
		}
	}

	stuck, err := s.billing.Store().ListStripeWithdrawalsByStatus("transferred", cutoff, stripeReconcileBatch)
	if err != nil {
		s.logger.Error("stripe reconciler: list stuck withdrawals failed", "error", err)
		return
	}
	if len(stuck) == 0 {
		return
	}

	// Group by connected account — one Stripe lookup (and at most one
	// schedule heal) per account, not per withdrawal. Track the oldest row
	// per account so weekly-schedule accounts can be judged against their
	// own (longer) threshold.
	type acctStuck struct {
		count  int
		oldest time.Time
	}
	byAcct := map[string]*acctStuck{}
	for _, wd := range stuck {
		st, ok := byAcct[wd.StripeAccountID]
		if !ok {
			st = &acctStuck{oldest: wd.CreatedAt}
			byAcct[wd.StripeAccountID] = st
		}
		st.count++
		if wd.CreatedAt.Before(st.oldest) {
			st.oldest = wd.CreatedAt
		}
	}
	s.logger.Info("stripe reconciler: withdrawals in transferred past base threshold",
		"withdrawals", len(stuck), "accounts", len(byAcct), "stuck_threshold", stripeStuckThreshold.String())

	for acctID, st := range byAcct {
		if acctID == "" {
			continue
		}
		acct, err := s.billing.StripeConnect().GetAccount(acctID)
		if err != nil {
			s.logger.Warn("stripe reconciler: account fetch failed",
				"stripe_account_id", acctID, "stuck_withdrawals", st.count, "error", err)
			continue
		}
		if acct.PayoutInterval == "manual" {
			if err := s.billing.StripeConnect().UpdateAccountPayoutScheduleAuto(acctID, acct.Country); err != nil {
				s.logger.Error("stripe reconciler: payout schedule heal failed",
					"stripe_account_id", acctID, "stuck_withdrawals", st.count, "error", err)
				continue
			}
			s.logger.Info("stripe reconciler: healed manual payout schedule to automatic",
				"stripe_account_id", acctID, "stuck_withdrawals", st.count)
			continue
		}
		// Weekly-schedule accounts (JP) legitimately hold rows in
		// "transferred" far longer than the base threshold — only alert
		// once the oldest row exceeds the weekly bound.
		if acct.PayoutInterval == "weekly" &&
			time.Since(st.oldest) < stripeStuckThresholdWeekly {
			s.logger.Info("stripe reconciler: withdrawals in normal weekly-payout transit",
				"stripe_account_id", acctID, "withdrawals", st.count,
				"oldest_created_at", st.oldest, "weekly_threshold", stripeStuckThresholdWeekly.String())
			continue
		}
		// Schedule is already automatic — the sweep should be moving these.
		// Loud log for ops: likely payouts_enabled=false (user needs to fix
		// bank details) or a failed sweep that keeps retrying.
		s.logger.Warn("stripe reconciler: stuck withdrawals on auto-schedule account",
			"stripe_account_id", acctID, "stuck_withdrawals", st.count,
			"payouts_enabled", acct.PayoutsEnabled,
			"disabled_reason", acct.DisabledReason,
			"payout_interval", acct.PayoutInterval)
	}
}
