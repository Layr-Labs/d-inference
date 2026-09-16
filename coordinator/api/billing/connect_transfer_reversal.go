package billing

import (
	"errors"

	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleTransferFailed handles the rare case where Stripe rolls back a transfer
// after we've considered it successful. This is the only event that re-credits
// the ledger principal: the money is actually back at the platform.
//
// Only FULL reversals (reversed=true, i.e. amount_reversed == amount) refund
// automatically and terminalize the row; partial reversals are ops-initiated
// and alert for manual review instead (see the inline comment).
//
// The refund is split into two reference-idempotent credits — principal-net
// (gross − fee) and the fee — so it composes with the instant-fee refund
// path: whichever path credited the fee first wins, and no interleaving of
// crashes and redeliveries can pay either part twice.
func (s *Controller) handleTransferFailed(event *billingservice.WebhookEvent) error {
	te, err := s.billing().StripeConnect().TransferFromEvent(event)
	if err != nil {
		s.logger.Warn("stripe connect webhook: transfer parse failed", "error", err)
		return nil
	}
	wd, err := s.billing().Store().GetStripeWithdrawalByTransferID(te.ID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return nil // not a transfer we created
		}
		s.logger.Error("stripe connect webhook: transfer lookup failed",
			"transfer_id", te.ID, "error", err)
		return err
	}
	if wd.Status == "paid" {
		// The user's bank payout completed AND the transfer reversed — an
		// ambiguous clawback state. Never auto-refund a paid row; surface it
		// for a human decision.
		s.logger.Error("stripe connect webhook: transfer reversed on an already-paid withdrawal — manual review required",
			"withdrawal_id", wd.ID, "transfer_id", te.ID, "stripe_account_id", wd.StripeAccountID)
		return nil
	}
	if wd.Refunded {
		// Terminal (covers legacy rows refunded under the old semantics).
		// This status flip is what keeps the already-refunded row out of
		// sweep reconciliation — if it fails, return the error so Stripe
		// redelivers rather than leaving a refunded row claimable.
		if wd.Status != "failed" {
			next := *wd
			next.Status = "failed"
			if _, err := s.billing().Store().CompareAndSwapStripeWithdrawal(wd, &next); err != nil {
				s.logger.Error("stripe connect webhook: refunded-row status flip failed",
					"error", err, "withdrawal_id", wd.ID)
				return err
			}
		}
		return nil
	}
	if !te.Reversed {
		// PARTIAL reversal: Stripe only sets reversed=true once
		// amount_reversed == amount. Our code never creates reversals, so a
		// partial one is always a deliberate ops action in the dashboard —
		// often precisely because the ledger was already adjusted by hand
		// (e.g. clawing back a historical double-refund). Auto-crediting the
		// full net here would over-pay, and auto-crediting the partial
		// amount can double-pay against the manual adjustment the reversal
		// is compensating for. No automatic ledger movement: surface for
		// the human who initiated it. The row stays non-terminal so the
		// sweep/reconciler keep watching the remaining funds.
		s.logger.Error("stripe connect webhook: PARTIAL transfer reversal — no automatic refund, manual ledger review required",
			"withdrawal_id", wd.ID, "transfer_id", te.ID,
			"amount_cents", te.AmountCents, "amount_reversed_cents", te.AmountReversedCents,
			"stripe_account_id", wd.StripeAccountID)
		return nil
	}
	// Recheck the current row while locking it for the whole refund. A
	// payout.paid that won after the lookup must not receive an automatic
	// refund, and a credit cannot become visible before the terminal state.
	applied, err := s.billing().Store().RefundStripeWithdrawalAfterReversal(wd.ID, te.ID)
	if err != nil {
		s.logger.Error("stripe connect webhook: reversal settlement failed", "error", err, "withdrawal_id", wd.ID)
		return err
	}
	if !applied {
		s.logger.Warn("stripe connect webhook: reversal not applied — withdrawal changed concurrently, review current state",
			"withdrawal_id", wd.ID, "transfer_id", te.ID)
	}
	return nil
}
