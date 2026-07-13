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

// stripeRecipientTransferDelay is how long a platform transfer takes to
// become available in a recipient-agreement connected account's balance
// (documented Stripe behavior: +24h). The sweep matcher uses it as the
// settlement-safe cutoff when attributing automatic payouts to rows.
const stripeRecipientTransferDelay = 24 * time.Hour

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
// A failure can arrive after payout.paid (banks bounce payouts days later);
// in that case the row is reopened to "transferred" so the retrying sweep
// stays observable — see the inline comment on the failure branch.
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

	if success {
		// Idempotent redelivery of payout.paid on a completed row.
		if wd.Status == "paid" {
			return nil
		}
		// The flip is guarded INSIDE the store (only pending/transferred +
		// !Refunded rows flip): a concurrent payout.failed/transfer.reversed
		// delivery that persisted Refunded after our read above can't be
		// overwritten by this stale copy.
		applied, err := s.billing.Store().MarkStripeWithdrawalPaid(wd.ID, pe.ID, "")
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
	// provably about the row's own in-flight payout — not a stale one — so we
	// reopen the row for the sweep to retry. Stale failures from an older
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

	// Reopen for the sweep to retry: status back to "transferred" with the
	// dead payout ID detached (the sweep matcher only completes rows with
	// no in-flight payout of their own). The transition is guarded INSIDE
	// the store: if a concurrent transfer.reversed terminalized the row
	// (Refunded/failed) after our read above, this stale copy cannot
	// overwrite the refund back to a sweep-eligible state.
	reason := "payout_failed " + pe.FailureCode + ": " + pe.FailureReason +
		" (payout " + pe.ID + "; auto-payout will retry)"
	applied, err := s.billing.Store().ReopenStripeWithdrawalAfterPayoutFailure(wd.ID, reason, wd.FeeRefunded)
	if err != nil {
		s.logger.Error("stripe connect webhook: persist payout failure failed",
			"error", err, "withdrawal_id", wd.ID)
		return err
	}
	if !applied {
		s.logger.Warn("stripe connect webhook: payout failure not applied — row terminalized concurrently (reversal wins)",
			"withdrawal_id", wd.ID, "payout_id", pe.ID)
		return nil
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
// covers the balance AVAILABLE at its creation time, so on payout.paid we
// mark every "transferred" row whose funds had become available by then as
// "paid". Transfers to recipient-agreement accounts take +24h to become
// available, so rows younger than that cannot be in this sweep — claiming
// them early would hide a row from the 48h stuck detector if the NEXT sweep
// then failed. Full-agreement transfers are available immediately, and their
// rows must be claimed by the same-day sweep (a later sweep may never come
// if the balance is empty). The availability delay is derived from the
// account's service agreement.
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
	if !success {
		// Sweep failed — funds stay in the connected balance and Stripe
		// retries on the next scheduled payout (typically after the user
		// fixes their bank details; account.updated flips them to
		// "restricted" when Stripe requires action). No ledger movement,
		// but rows this same sweep previously marked "paid" (its paid event
		// can precede a bank bounce) must reopen so they stay observable.
		return s.reopenSweepBouncedRows(pe)
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

	// Webhook delivery order is not guaranteed: a stale payout.paid can be
	// delivered AFTER the same payout already failed (whose failure event,
	// finding nothing stamped yet, was necessarily a no-op). Confirm the
	// payout is still live-"paid" before attributing rows to it.
	livePayout, perr := s.billing.StripeConnect().GetPayout(pe.ConnectedAcct, pe.ID)
	if perr != nil {
		if billing.IsAccountGoneErr(perr) {
			s.logger.Warn("stripe connect webhook: sweep reconcile skipped — account gone",
				"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID)
			return nil
		}
		s.logger.Error("stripe connect webhook: sweep payout live-status check failed",
			"error", perr, "payout_id", pe.ID)
		return perr // redeliver
	}
	if livePayout.Status != "paid" {
		s.logger.Warn("stripe connect webhook: stale sweep payout.paid — payout is no longer paid, not claiming rows",
			"payout_id", pe.ID, "live_status", livePayout.Status,
			"stripe_account_id", pe.ConnectedAcct)
		return nil
	}

	// Settlement-safe cutoff: recipient-agreement transfers become available
	// +24h after creation, so this sweep cannot contain them until then.
	availabilityDelay := time.Duration(0)
	acct, aerr := s.billing.StripeConnect().GetAccount(pe.ConnectedAcct)
	if aerr != nil {
		if billing.IsAccountGoneErr(aerr) {
			// Account deleted after the sweep fired — nothing left to claim
			// safely; the 48h reconciler surfaces any stragglers.
			s.logger.Warn("stripe connect webhook: sweep reconcile skipped — account gone",
				"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID)
			return nil
		}
		// Transient — redeliver rather than guess the wrong cutoff in
		// either direction.
		s.logger.Error("stripe connect webhook: sweep reconcile account fetch failed",
			"error", aerr, "stripe_account_id", pe.ConnectedAcct)
		return aerr
	}
	if billing.NormalizeServiceAgreement(acct.ServiceAgreement) == billing.ServiceAgreementRecipient {
		availabilityDelay = stripeRecipientTransferDelay
	}

	payoutCreated := time.Unix(pe.Created, 0)
	settledBefore := payoutCreated.Add(-availabilityDelay)

	// The account list is capped (MaxStripeWithdrawalsByStatusLimit) and
	// Stripe never redelivers an acked payout.paid — so keep claiming pages
	// until a page comes back short or makes no progress. Claimed rows
	// leave the "transferred" filter, so each iteration sees the remainder.
	totalMarked := 0
	var firstErr error
	for page := 0; page < 50; page++ {
		if page > 0 {
			rows, err = s.billing.Store().ListStripeWithdrawalsForStripeAccount(pe.ConnectedAcct, "transferred")
			if err != nil {
				s.logger.Error("stripe connect webhook: sweep reconcile list failed",
					"error", err, "stripe_account_id", pe.ConnectedAcct)
				firstErr = err
				break
			}
		}
		marked := 0
		for i := range rows {
			wd := &rows[i]
			if wd.PayoutID != "" {
				continue // in-flight instant payout — its own webhook drives it
			}
			if wd.Refunded {
				continue // ledger already refunded (legacy state) — never mark paid
			}
			// The row must have REACHED its current "transferred" state
			// (UpdatedAt ≈ when the transfer completed) at least the
			// availability delay before the sweep was cut — a row that was
			// still pending, mid-transfer, or inside the recipient +24h
			// window when the sweep was created cannot have its funds in
			// that sweep. Anchoring on UpdatedAt rather than CreatedAt also
			// covers rows that sat parked/pending long after creation, and
			// rows reopened by a sweep bounce (fresh UpdatedAt), so a
			// redelivered payout.paid from the OLD (bounced) sweep can't
			// re-claim them — only a sweep cut after the funds actually
			// (re-)settled completes the row.
			if pe.Created > 0 && wd.UpdatedAt.After(settledBefore) {
				continue
			}
			// Guarded flip (store-side): a concurrent refund/failure
			// delivery can't be overwritten by this loop's stale copy, and
			// the payout_id='' condition rejects rows that acquired an
			// in-flight payout since our read. The sweep payout ID is
			// stamped so a later bounce (payout.failed after paid) can
			// reopen exactly these rows via reopenSweepBouncedRows.
			applied, merr := s.billing.Store().MarkStripeWithdrawalPaid(wd.ID, "", pe.ID)
			if merr != nil {
				s.logger.Error("stripe connect webhook: sweep mark paid failed",
					"error", merr, "withdrawal_id", wd.ID)
				if firstErr == nil {
					firstErr = merr
				}
				continue
			}
			if applied {
				marked++
			}
		}
		totalMarked += marked
		if firstErr != nil || marked == 0 || len(rows) < store.MaxStripeWithdrawalsByStatusLimit {
			break
		}
	}
	if totalMarked > 0 {
		s.logger.Info("stripe connect webhook: sweep payout reconciled",
			"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID, "withdrawals_paid", totalMarked)
	}
	// A partial failure redelivers; rows already marked "paid" drop out of
	// the "transferred" list, so the retry only touches the stragglers.
	return firstErr
}

// reopenSweepBouncedRows handles payout.failed / payout.canceled for an
// automatic sweep payout. Funds are back in the connected balance and the
// next scheduled sweep retries, so there is no ledger movement — but rows
// this same sweep already marked "paid" (its paid event can precede a bank
// bounce by days) must reopen to "transferred": left "paid" they would hide
// funds that are actually parked in the connected balance from both the
// sweep matcher and the 48h stuck detector. Rows are found via the
// SweepPayoutID stamped when the sweep claimed them; rows claimed by other
// sweeps are untouched.
func (s *Server) reopenSweepBouncedRows(pe *billing.PayoutEvent) error {
	failureReason := "sweep_payout_failed " + pe.FailureCode + ": " + pe.FailureReason +
		" (payout " + pe.ID + "; next sweep will retry)"
	if err := s.billing.Store().RecordStripeSweepFailure(pe.ID, failureReason); err != nil {
		s.logger.Error("stripe connect webhook: sweep failure tombstone failed",
			"error", err, "stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID)
		return err
	}
	// Looked up by the sweep stamp directly (not by scanning the account's
	// paid rows): exact, and immune to any per-account list bound.
	paid, err := s.billing.Store().ListStripeWithdrawalsBySweepPayoutID(pe.ID)
	if err != nil {
		s.logger.Error("stripe connect webhook: sweep bounce list failed",
			"error", err, "stripe_account_id", pe.ConnectedAcct)
		return err // redeliver
	}
	reopened := 0
	var firstErr error
	for i := range paid {
		wd := &paid[i]
		if wd.Status != "paid" || wd.Refunded {
			continue
		}
		applied, err := s.billing.Store().ReopenStripeWithdrawalAfterSweepFailure(
			wd.ID, pe.ID, failureReason,
		)
		if err != nil {
			s.logger.Error("stripe connect webhook: sweep bounce reopen failed",
				"error", err, "withdrawal_id", wd.ID)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if applied {
			reopened++
		}
	}
	s.logger.Warn("stripe connect webhook: sweep payout failed — will retry on next schedule",
		"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID,
		"failure_code", pe.FailureCode, "reopened_withdrawals", reopened)
	// Partial persist failures redeliver; reopened rows drop out of the
	// "paid" list, so the retry only touches the stragglers.
	return firstErr
}

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
	if wd.Refunded {
		// Terminal (covers legacy rows refunded under the old semantics).
		// This status flip is what keeps the already-refunded row out of
		// sweep reconciliation — if it fails, return the error so Stripe
		// redelivers rather than leaving a refunded row claimable.
		if wd.Status != "failed" {
			wd.Status = "failed"
			if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
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
	refunded, manualReview, err := s.billing.Store().RefundStripeWithdrawalOnReversal(wd.ID)
	if err != nil {
		s.logger.Error("stripe connect webhook: atomic reversal refund failed",
			"error", err, "withdrawal_id", wd.ID)
		return err
	}
	if manualReview {
		s.logger.Error("stripe connect webhook: transfer reversed on an already-paid withdrawal — manual review required",
			"withdrawal_id", wd.ID, "transfer_id", te.ID, "stripe_account_id", wd.StripeAccountID)
		return nil
	}
	if refunded {
		s.logger.Warn("stripe connect webhook: reversed transfer refunded atomically",
			"withdrawal_id", wd.ID, "transfer_id", te.ID)
	}
	return nil
}
