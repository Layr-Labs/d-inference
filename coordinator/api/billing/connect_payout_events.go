package billing

import (
	"errors"

	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handlePayoutTerminal handles payout.paid / payout.failed / payout.canceled.
//
// Success: the row (matched by payout ID, or by connected account for
// automatic sweep payouts we never created) is marked "paid".
//
// Failure: the funds return to the connected account's Stripe balance and the
// automatic daily payout schedule retries delivery — so we do NOT re-credit
// the ledger (that would double-pay: once from the ledger refund and again
// when the sweep eventually reaches the user's bank). The instant fee IS
// refunded (once, keyed on FeeRefunded): the user paid for instant delivery
// and is getting the standard rail instead. The dead payout ID is detached
// from the row so the sweep matcher can complete it when the daily sweep
// delivers. Ledger principal refunds only happen on transfer.reversed, where
// the money actually returns to the platform.
//
// A failure can arrive after payout.paid (banks bounce payouts days later);
// in that case the row is reopened to "transferred" so the retrying sweep
// stays observable — see the inline comment on the failure branch.
//
// Returns a non-nil error only for transient store failures, so the webhook
// responds non-2xx and Stripe redelivers.
func (s *Controller) handlePayoutTerminal(event *billingservice.WebhookEvent, connectedAcct string, success bool) error {
	pe, err := s.billing().StripeConnect().PayoutFromEvent(event, connectedAcct)
	if err != nil {
		s.logger.Warn("stripe connect webhook: payout parse failed", "error", err)
		return nil
	}

	wd, err := s.billing().Store().GetStripeWithdrawalByPayoutID(pe.ID)
	if err != nil {
		if !errors.Is(err, store.ErrNotFound) {
			// Transient store failure — do NOT fall through to account-wide
			// reconciliation (that could claim unrelated rows for this
			// payout). Redeliver instead.
			s.logger.Error("stripe connect webhook: payout lookup failed",
				"payout_id", pe.ID, "error", err)
			return err
		}
		// Not a payout we created — either Stripe's automatic sweep (the
		// normal delivery path for standard withdrawals) or a payout made
		// directly in the dashboard. Reconcile it against this connected
		// account's outstanding "transferred" rows.
		return s.reconcileUnmatchedPayout(pe, success)
	}

	if success {
		// Idempotent redelivery of payout.paid on a completed row.
		if wd.Status == "paid" {
			return nil
		}
		// The flip is guarded INSIDE the store (only pending/transferred +
		// !Refunded rows flip): a concurrent payout.failed/transfer.reversed
		// delivery that persisted Refunded after our read above can't be
		// overwritten by this stale copy.
		applied, err := s.billing().Store().MarkStripeWithdrawalPaid(wd.ID, pe.ID, "")
		if err != nil {
			s.logger.Error("stripe connect webhook: mark paid failed", "error", err)
			return err
		}
		if !applied {
			// Refunded or already terminal — e.g. the ledger was refunded
			// (transfer.reversed) AND the payout delivered; the user may
			// hold both. Never overwrite; escalate for manual review.
			s.logger.Error("stripe connect webhook: payout.paid on a refunded/terminal withdrawal — possible double payment, manual review required",
				"withdrawal_id", wd.ID, "payout_id", pe.ID, "status", wd.Status,
				"stripe_account_id", wd.StripeAccountID)
		}
		return nil
	}

	// Matched payout failed. Funds are back in the connected account balance;
	// the daily sweep will retry via the standard rail.
	//
	// This applies to "paid" rows too: Stripe documents payout.failed arriving
	// AFTER payout.paid for the same payout when the bank later bounces it.
	// Because this row was looked up BY the event's payout ID, the failure is
	// about the observed in-flight payout. The store rechecks that ownership
	// before applying the transition: a concurrent failure may detach it and a
	// newer sweep may complete the row after this lookup. For a match, we
	// reopen the row for the sweep to retry. Later failures from an older
	// payout can never reach this path: processing a failure detaches the
	// payout ID from the row (below), so a redelivered or out-of-order event
	// for that payout misses the lookup and falls into
	// reconcileUnmatchedPayout, which ignores non-automatic payouts.
	if wd.Refunded {
		if wd.Status == "paid" {
			// Refunded AND paid — the ledger was already made whole under
			// the old semantics while the bank payout completed. Ambiguous
			// clawback state; never touch it automatically.
			s.logger.Error("stripe connect webhook: payout failed on a paid+refunded withdrawal — manual review required",
				"withdrawal_id", wd.ID, "payout_id", pe.ID)
			return nil
		}
		// Legacy row already refunded under the old semantics — leave it
		// terminal so we never double-account.
		if wd.Status != "failed" {
			wd.Status = "failed"
			if err := s.billing().Store().UpdateStripeWithdrawal(wd); err != nil {
				s.logger.Error("stripe connect webhook: status flip failed", "error", err)
				return err
			}
		}
		return nil
	}

	// The user paid for instant delivery and is getting the standard sweep
	// instead — refund the fee. The credit is idempotent on its ledger
	// reference, so any crash/redelivery interleaving converges: a retried
	// event skips the credit and re-attempts only the row persist.
	if wd.FeeMicroUSD > 0 && !wd.FeeRefunded {
		if _, err := s.billing().Store().CreditWithdrawableOnce(wd.AccountID, wd.FeeMicroUSD,
			store.LedgerRefund, "stripe_withdraw_fee:"+wd.ID); err != nil {
			s.logger.Error("stripe connect webhook: instant fee refund failed",
				"error", err, "withdrawal_id", wd.ID)
			return err
		}
		wd.FeeRefunded = true
	}

	// Reopen for the sweep to retry: status back to "transferred" with the
	// dead payout ID detached (the sweep matcher only completes rows with
	// no in-flight payout of their own). The transition is guarded INSIDE
	// the store: if a concurrent transfer.reversed terminalized the row
	// (Refunded/failed) after our read above, this stale copy cannot
	// overwrite the refund back to a sweep-eligible state.
	reason := "payout_failed " + pe.FailureCode + ": " + pe.FailureReason +
		" (payout " + pe.ID + "; auto-payout will retry)"
	applied, err := s.billing().Store().ReopenStripeWithdrawalAfterPayoutFailure(wd.ID, pe.ID, reason, wd.FeeRefunded)
	if err != nil {
		s.logger.Error("stripe connect webhook: persist payout failure failed",
			"error", err, "withdrawal_id", wd.ID)
		return err
	}
	if !applied {
		s.logger.Warn("stripe connect webhook: payout failure not applied — row terminalized or payout ownership changed concurrently",
			"withdrawal_id", wd.ID, "payout_id", pe.ID)
		return nil
	}
	s.logger.Warn("stripe connect webhook: payout failed — funds returned to connected balance, sweep will retry",
		"withdrawal_id", wd.ID, "payout_id", pe.ID,
		"failure_code", pe.FailureCode, "failure_reason", pe.FailureReason,
		"fee_refunded", wd.FeeRefunded)
	return nil
}
