package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleStripeConnectWebhook handles POST /v1/billing/stripe/connect/webhook.
// Drives the local withdrawal state machine for Connect events. This is a
// separate endpoint from the Checkout webhook because Stripe lets you
// configure per-endpoint signing secrets.
//
// Transient store failures return a non-2xx so Stripe redelivers the event;
// malformed payloads and business no-ops are acked with 200 (redelivery
// cannot fix those).
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

	var handleErr error
	switch event.Type {
	case "account.updated":
		// Best-effort mirror: account.updated recurs on every account change
		// and the status endpoint re-syncs on page load, so a dropped event
		// self-heals without redelivery.
		s.handleAccountUpdated(event)
	case "payout.paid":
		handleErr = s.handlePayoutTerminal(event, envelope.Account, true)
	case "payout.failed", "payout.canceled":
		handleErr = s.handlePayoutTerminal(event, envelope.Account, false)
	case "transfer.reversed":
		handleErr = s.handleTransferFailed(event)
	default:
		// Ignore everything else — we just ack.
	}
	if handleErr != nil {
		http.Error(w, "transient failure — retry", http.StatusInternalServerError)
		return
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
// when the sweep eventually reaches the user's bank). The instant fee IS
// refunded (once, keyed on FeeRefunded): the user paid for instant delivery
// and is getting the standard rail instead. The dead payout ID is detached
// from the row so the sweep matcher can complete it when the daily sweep
// delivers. Ledger principal refunds only happen on transfer.reversed, where
// the money actually returns to the platform.
//
// Returns a non-nil error only for transient store failures, so the webhook
// responds non-2xx and Stripe redelivers.
func (s *Server) handlePayoutTerminal(event *billing.WebhookEvent, connectedAcct string, success bool) error {
	pe, err := s.billing.StripeConnect().PayoutFromEvent(event, connectedAcct)
	if err != nil {
		s.logger.Warn("stripe connect webhook: payout parse failed", "error", err)
		return nil
	}

	wd, err := s.billing.Store().GetStripeWithdrawalByPayoutID(pe.ID)
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

	// "paid" is terminal: nothing after this changes the ledger. This also
	// guards redelivered/out-of-order payout.failed events arriving after the
	// row was completed (by this payout's own paid event or by a sweep).
	if wd.Status == "paid" {
		return nil
	}

	if success {
		wd.Status = "paid"
		if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
			s.logger.Error("stripe connect webhook: mark paid failed", "error", err)
			return err
		}
		return nil
	}

	// Matched payout failed. Funds are back in the connected account balance;
	// the daily sweep will retry via the standard rail.
	if wd.Refunded {
		// Legacy row already refunded under the old semantics — leave it
		// terminal so we never double-account.
		if wd.Status != "failed" {
			wd.Status = "failed"
			if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
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
		if _, err := s.billing.Store().CreditWithdrawableOnce(wd.AccountID, wd.FeeMicroUSD,
			store.LedgerRefund, "stripe_withdraw_fee:"+wd.ID); err != nil {
			s.logger.Error("stripe connect webhook: instant fee refund failed",
				"error", err, "withdrawal_id", wd.ID)
			return err
		}
		wd.FeeRefunded = true
	}

	wd.Status = "transferred"
	wd.FailureReason = "payout_failed " + pe.FailureCode + ": " + pe.FailureReason +
		" (payout " + pe.ID + "; auto-payout will retry)"
	// Detach the dead payout ID: the sweep matcher only completes rows with
	// no in-flight payout of their own.
	wd.PayoutID = ""
	if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
		s.logger.Error("stripe connect webhook: persist payout failure failed",
			"error", err, "withdrawal_id", wd.ID)
		return err
	}
	s.logger.Warn("stripe connect webhook: payout failed — funds returned to connected balance, sweep will retry",
		"withdrawal_id", wd.ID, "payout_id", pe.ID,
		"failure_code", pe.FailureCode, "failure_reason", pe.FailureReason,
		"fee_refunded", wd.FeeRefunded)
	return nil
}

// reconcileUnmatchedPayout maps an automatic sweep payout (created by Stripe's
// daily payout schedule, so its ID is unknown to us) back onto local
// withdrawal rows for the same connected account.
//
// Only automatic payouts reconcile: a dashboard/API payout we didn't create
// has no attributable rows, and blanket-claiming them would mark withdrawals
// paid that the payout may not cover. Rows with an in-flight instant payout
// of their own (PayoutID set) are skipped — their own payout.paid/failed
// drives them.
//
// We deliberately do NOT match on amount: a sweep payout is denominated in
// the connected account's settlement currency (EUR, AUD, …) after Stripe's
// FX conversion, so it is not comparable to our USD row amounts. A sweep
// covers the balance available at its creation time, so on payout.paid we
// mark every eligible "transferred" row created before the payout as "paid".
// Rows whose transfer hadn't settled by then (e.g. the +24h availability
// delay on recipient accounts) may be marked a sweep early — a cosmetic
// status-display tradeoff, not a money movement: the ledger was already
// debited and the funds are en route either way. Genuinely stuck rows are
// caught by the 48h reconciler alert.
func (s *Server) reconcileUnmatchedPayout(pe *billing.PayoutEvent, success bool) error {
	if pe.ConnectedAcct == "" {
		s.logger.Debug("stripe connect webhook: unknown payout without account", "payout_id", pe.ID)
		return nil
	}
	if !pe.Automatic {
		s.logger.Info("stripe connect webhook: ignoring non-automatic payout we didn't create",
			"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID, "success", success)
		return nil
	}
	rows, err := s.billing.Store().ListStripeWithdrawalsForStripeAccount(pe.ConnectedAcct, "transferred")
	if err != nil {
		s.logger.Error("stripe connect webhook: sweep reconcile list failed",
			"error", err, "stripe_account_id", pe.ConnectedAcct)
		return err
	}
	if len(rows) == 0 {
		return nil
	}

	if !success {
		// Sweep failed — funds stay in the connected balance and Stripe
		// retries on the next scheduled payout (typically after the user
		// fixes their bank details; account.updated flips them to
		// "restricted" when Stripe requires action). No ledger movement.
		s.logger.Warn("stripe connect webhook: sweep payout failed — will retry on next schedule",
			"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID,
			"failure_code", pe.FailureCode, "outstanding_withdrawals", len(rows))
		return nil
	}

	payoutCreated := time.Unix(pe.Created, 0)
	marked := 0
	var firstErr error
	for i := range rows {
		wd := &rows[i]
		if wd.PayoutID != "" {
			continue // in-flight instant payout — its own webhook drives it
		}
		if pe.Created > 0 && wd.CreatedAt.After(payoutCreated) {
			continue // transferred after this sweep was cut — next sweep covers it
		}
		wd.Status = "paid"
		if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
			s.logger.Error("stripe connect webhook: sweep mark paid failed",
				"error", err, "withdrawal_id", wd.ID)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		marked++
	}
	if marked > 0 {
		s.logger.Info("stripe connect webhook: sweep payout reconciled",
			"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID, "withdrawals_paid", marked)
	}
	// A partial failure redelivers; rows already marked "paid" drop out of
	// the "transferred" list, so the retry only touches the stragglers.
	return firstErr
}

// handleTransferFailed handles the rare case where Stripe rolls back a transfer
// after we've considered it successful. This is the only event that re-credits
// the ledger principal: the money is actually back at the platform.
//
// The refund is split into two reference-idempotent credits — principal-net
// (gross − fee) and the fee — so it composes with the instant-fee refund
// path: whichever path credited the fee first wins, and no interleaving of
// crashes and redeliveries can pay either part twice.
func (s *Server) handleTransferFailed(event *billing.WebhookEvent) error {
	te, err := s.billing.StripeConnect().TransferFromEvent(event)
	if err != nil {
		s.logger.Warn("stripe connect webhook: transfer parse failed", "error", err)
		return nil
	}
	wd, err := s.billing.Store().GetStripeWithdrawalByTransferID(te.ID)
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
		if wd.Status != "failed" {
			wd.Status = "failed"
			_ = s.billing.Store().UpdateStripeWithdrawal(wd)
		}
		return nil
	}
	netMicroUSD := wd.AmountMicroUSD - wd.FeeMicroUSD
	if netMicroUSD > 0 {
		if _, err := s.billing.Store().CreditWithdrawableOnce(wd.AccountID, netMicroUSD,
			store.LedgerRefund, "stripe_withdraw:"+wd.ID); err != nil {
			s.logger.Error("stripe connect webhook: principal refund failed", "error", err, "withdrawal_id", wd.ID)
			return err // Refunded stays false — redelivery retries idempotently
		}
	}
	if wd.FeeMicroUSD > 0 {
		// No-ops if the instant-fee path already credited this reference.
		applied, err := s.billing.Store().CreditWithdrawableOnce(wd.AccountID, wd.FeeMicroUSD,
			store.LedgerRefund, "stripe_withdraw_fee:"+wd.ID)
		if err != nil {
			s.logger.Error("stripe connect webhook: fee refund failed", "error", err, "withdrawal_id", wd.ID)
			return err
		}
		if applied {
			wd.FeeRefunded = true
		}
	}
	wd.Refunded = true
	wd.Status = "failed"
	wd.FailureReason = "transfer_reversed"
	if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
		// Credits are reference-idempotent — redelivery skips them and
		// retries this persist.
		s.logger.Error("stripe connect webhook: mark failed failed", "error", err)
		return err
	}
	return nil
}
