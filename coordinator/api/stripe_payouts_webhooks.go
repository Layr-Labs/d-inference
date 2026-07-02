package api

// Stripe Connect webhook state machine — POST /v1/billing/stripe/connect/webhook.
//
// Drives local withdrawal rows via account.updated, payout.paid,
// payout.failed/canceled, and transfer.reversed. Automatic sweep payouts
// (created by Stripe's daily payout schedule, so their IDs are unknown to us)
// are reconciled back to rows by connected account. Only transfer.reversed
// re-credits the ledger — a failed payout leaves the funds in the connected
// account where the next sweep retries delivery.

import (
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleStripeConnectWebhook handles POST /v1/billing/stripe/connect/webhook.
// Drives the local state machine for Connect events. This is a separate
// endpoint from the Checkout webhook because Stripe lets you configure
// per-endpoint signing secrets.
func (s *Server) handleStripeConnectWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.StripeConnect() == nil {
		http.Error(w, "Stripe Connect not configured", http.StatusServiceUnavailable)
		return
	}

	payload, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	sig := r.Header.Get("Stripe-Signature")
	event, err := s.billing.StripeConnect().VerifyConnectWebhookSignature(payload, sig)
	if err != nil {
		s.logger.Warn("stripe connect webhook: signature verification failed", "error", err)
		http.Error(w, "invalid signature", http.StatusBadRequest)
		return
	}

	// Connect webhooks include the connected account ID at the top level
	// (event.account in Stripe's payload). We re-parse the raw payload to
	// pull it out; the WebhookEvent struct only exposes Type + Data.
	var envelope struct {
		Account string `json:"account"`
	}
	_ = json.Unmarshal(payload, &envelope)

	switch event.Type {
	case "account.updated":
		s.handleAccountUpdated(event)
	case "payout.paid":
		s.handlePayoutTerminal(event, envelope.Account, true)
	case "payout.failed", "payout.canceled":
		s.handlePayoutTerminal(event, envelope.Account, false)
	case "transfer.reversed":
		s.handleTransferFailed(event)
	default:
		// Ignore everything else — we just ack.
	}
	w.WriteHeader(http.StatusOK)
}

// handleAccountUpdated mirrors Stripe's view of the connected account into our
// User row. This is what flips a user from "pending" → "ready".
func (s *Server) handleAccountUpdated(event *billing.WebhookEvent) {
	acct, err := s.billing.StripeConnect().AccountUpdatedFromEvent(event)
	if err != nil {
		s.logger.Warn("stripe connect webhook: account.updated parse failed", "error", err)
		return
	}
	user, err := s.billing.Store().GetUserByStripeAccount(acct.ID)
	if err != nil {
		s.logger.Warn("stripe connect webhook: account.updated user lookup failed",
			"stripe_account_id", acct.ID, "error", err)
		return
	}
	status := stripeStatusForAccount(acct)
	if err := s.billing.Store().SetUserStripeAccount(user.AccountID, acct.ID,
		status, acct.Country, acct.DestinationType, acct.DestinationLast4, acct.InstantEligible); err != nil {
		s.logger.Error("stripe connect webhook: persist account state failed", "error", err)
	}
}

// handlePayoutTerminal handles payout.paid / payout.failed / payout.canceled.
//
// Success: the row (matched by payout ID, or by connected account for
// automatic sweep payouts we never created) is marked "paid".
//
// Failure: the funds return to the connected account's Stripe balance and the
// automatic daily payout schedule retries delivery — so we do NOT re-credit
// the ledger (that would double-pay: once from the ledger refund and again
// when the sweep eventually reaches the user's bank). We record the failure
// reason for ops visibility and leave the row "transferred". Ledger refunds
// only happen on transfer.reversed, where the money actually returns to the
// platform.
func (s *Server) handlePayoutTerminal(event *billing.WebhookEvent, connectedAcct string, success bool) {
	pe, err := s.billing.StripeConnect().PayoutFromEvent(event, connectedAcct)
	if err != nil {
		s.logger.Warn("stripe connect webhook: payout parse failed", "error", err)
		return
	}

	wd, err := s.billing.Store().GetStripeWithdrawalByPayoutID(pe.ID)
	if err != nil {
		// Not a payout we created — either Stripe's automatic sweep (the
		// normal delivery path for standard withdrawals) or a payout made
		// directly in the dashboard. Reconcile it against this connected
		// account's outstanding "transferred" rows.
		s.reconcileUnmatchedPayout(pe, success)
		return
	}

	if success {
		// payout.paid is idempotent: nothing changes the ledger, so a
		// repeated delivery just rewrites the row to "paid" again.
		if wd.Status == "paid" {
			return
		}
		wd.Status = "paid"
		if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
			s.logger.Error("stripe connect webhook: mark paid failed", "error", err)
		}
		return
	}

	// Matched payout failed. Funds are back in the connected account balance;
	// the daily sweep will retry via the standard rail. Keep the row
	// "transferred" so the sweep matcher can complete it later.
	if wd.Refunded {
		// Legacy row already refunded under the old semantics — leave it
		// terminal so we never double-account.
		if wd.Status != "failed" {
			wd.Status = "failed"
			if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
				s.logger.Error("stripe connect webhook: status flip failed", "error", err)
			}
		}
		return
	}
	wd.Status = "transferred"
	wd.FailureReason = "payout_failed " + pe.FailureCode + ": " + pe.FailureReason + " (auto-payout will retry)"
	if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
		s.logger.Error("stripe connect webhook: persist payout failure failed", "error", err)
	}
	s.logger.Warn("stripe connect webhook: payout failed — funds returned to connected balance, sweep will retry",
		"withdrawal_id", wd.ID, "payout_id", pe.ID,
		"failure_code", pe.FailureCode, "failure_reason", pe.FailureReason)
}

// reconcileUnmatchedPayout maps a payout we didn't create (Stripe's automatic
// daily sweep, or a dashboard-initiated payout) back onto local withdrawal
// rows for the same connected account.
//
// A sweep payout covers the balance available at its creation time, so on
// payout.paid we mark every "transferred" row created before the payout as
// "paid". Rows whose transfer hadn't settled by then (e.g. the +24h
// availability delay on recipient accounts) may be marked a sweep early —
// that's a cosmetic status-display tradeoff, not a money movement: the ledger
// was already debited and the funds are en route either way.
func (s *Server) reconcileUnmatchedPayout(pe *billing.PayoutEvent, success bool) {
	if pe.ConnectedAcct == "" {
		s.logger.Debug("stripe connect webhook: unknown payout without account", "payout_id", pe.ID)
		return
	}
	rows, err := s.billing.Store().ListStripeWithdrawalsForStripeAccount(pe.ConnectedAcct, "transferred")
	if err != nil {
		s.logger.Error("stripe connect webhook: sweep reconcile list failed",
			"error", err, "stripe_account_id", pe.ConnectedAcct)
		return
	}
	if len(rows) == 0 {
		return
	}

	if !success {
		// Sweep failed — funds stay in the connected balance and Stripe
		// retries on the next scheduled payout (typically after the user
		// fixes their bank details; account.updated flips them to
		// "restricted" when Stripe requires action). No ledger movement.
		s.logger.Warn("stripe connect webhook: sweep payout failed — will retry on next schedule",
			"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID,
			"failure_code", pe.FailureCode, "outstanding_withdrawals", len(rows))
		return
	}

	payoutCreated := time.Unix(pe.Created, 0)
	marked := 0
	for i := range rows {
		wd := &rows[i]
		if pe.Created > 0 && wd.CreatedAt.After(payoutCreated) {
			continue // transferred after this sweep was cut — next sweep covers it
		}
		wd.Status = "paid"
		if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
			s.logger.Error("stripe connect webhook: sweep mark paid failed",
				"error", err, "withdrawal_id", wd.ID)
			continue
		}
		marked++
	}
	if marked > 0 {
		s.logger.Info("stripe connect webhook: sweep payout reconciled",
			"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID, "withdrawals_paid", marked)
	}
}

// handleTransferFailed handles the rare case where Stripe rolls back a transfer
// after we've considered it successful. Same refund logic as a failed payout.
func (s *Server) handleTransferFailed(event *billing.WebhookEvent) {
	te, err := s.billing.StripeConnect().TransferFromEvent(event)
	if err != nil {
		s.logger.Warn("stripe connect webhook: transfer parse failed", "error", err)
		return
	}
	wd, err := s.billing.Store().GetStripeWithdrawalByTransferID(te.ID)
	if err != nil {
		return
	}
	// Idempotency keyed on Refunded so a redelivery after a transient credit
	// failure can still retry the refund.
	if wd.Refunded {
		if wd.Status != "failed" {
			wd.Status = "failed"
			_ = s.billing.Store().UpdateStripeWithdrawal(wd)
		}
		return
	}
	wd.FailureReason = "transfer_reversed"
	if err := s.billing.Store().CreditWithdrawable(wd.AccountID, wd.AmountMicroUSD, store.LedgerRefund,
		"stripe_withdraw:"+wd.ID); err != nil {
		s.logger.Error("stripe connect webhook: refund failed", "error", err, "withdrawal_id", wd.ID)
		wd.Status = "failed"
		_ = s.billing.Store().UpdateStripeWithdrawal(wd)
		return
	}
	wd.Refunded = true
	wd.Status = "failed"
	if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
		s.logger.Error("stripe connect webhook: mark failed failed", "error", err)
	}
}
