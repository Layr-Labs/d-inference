package api

import (
	"encoding/json"
	"io"
	"net/http"

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
		status, acct.DestinationType, acct.DestinationLast4, acct.InstantEligible); err != nil {
		s.logger.Error("stripe connect webhook: persist account state failed", "error", err)
	}
}

// handlePayoutTerminal handles payout.paid / payout.failed / payout.canceled.
// On success we mark the row "paid". On failure we mark "failed" and re-credit
// the user's ledger via LedgerRefund.
func (s *Server) handlePayoutTerminal(event *billing.WebhookEvent, _ string, success bool) {
	pe, err := s.billing.StripeConnect().PayoutFromEvent(event, "")
	if err != nil {
		s.logger.Warn("stripe connect webhook: payout parse failed", "error", err)
		return
	}
	wd, err := s.billing.Store().GetStripeWithdrawalByPayoutID(pe.ID)
	if err != nil {
		// Stripe may emit payout events for payouts created outside our flow
		// (e.g. directly in the dashboard) — silently ignore those.
		s.logger.Debug("stripe connect webhook: unknown payout", "payout_id", pe.ID)
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

	// payout.failed: refund the ledger if we haven't already, then mark
	// failed. We key idempotency on the Refunded flag (not Status) so a
	// previously-failed-but-refund-failed row gets retried on webhook
	// redelivery.
	if wd.Refunded {
		// Already refunded — make sure status is terminal and bail.
		if wd.Status != "failed" {
			wd.Status = "failed"
			if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
				s.logger.Error("stripe connect webhook: status flip failed", "error", err)
			}
		}
		return
	}
	wd.FailureReason = pe.FailureCode + ": " + pe.FailureReason
	if err := s.billing.Store().CreditWithdrawable(wd.AccountID, wd.AmountMicroUSD, store.LedgerRefund,
		"stripe_withdraw:"+wd.ID); err != nil {
		s.logger.Error("stripe connect webhook: refund failed", "error", err, "withdrawal_id", wd.ID)
		// Still update the row so we know about the failure even if the
		// refund needs manual intervention.
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
