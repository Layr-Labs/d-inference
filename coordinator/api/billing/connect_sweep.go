package billing

import (
	"time"

	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// stripeRecipientTransferDelay is how long a platform transfer takes to
// become available in a recipient-agreement connected account's balance
// (documented Stripe behavior: +24h). The sweep matcher uses it as the
// settlement-safe cutoff when attributing automatic payouts to rows.
const stripeRecipientTransferDelay = 24 * time.Hour

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
func (s *Controller) reconcileUnmatchedPayout(pe *billingservice.PayoutEvent, success bool) error {
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

	rows, err := s.billing().Store().ListStripeWithdrawalsForStripeAccount(pe.ConnectedAcct, "transferred")
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
	livePayout, perr := s.billing().StripeConnect().GetPayout(pe.ConnectedAcct, pe.ID)
	if perr != nil {
		if billingservice.IsAccountGoneErr(perr) {
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
	acct, aerr := s.billing().StripeConnect().GetAccount(pe.ConnectedAcct)
	if aerr != nil {
		if billingservice.IsAccountGoneErr(aerr) {
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
	if billingservice.NormalizeServiceAgreement(acct.ServiceAgreement) == billingservice.ServiceAgreementRecipient {
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
			rows, err = s.billing().Store().ListStripeWithdrawalsForStripeAccount(pe.ConnectedAcct, "transferred")
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
			applied, merr := s.billing().Store().MarkStripeWithdrawalPaid(wd.ID, "", pe.ID)
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
func (s *Controller) reopenSweepBouncedRows(pe *billingservice.PayoutEvent) error {
	// Looked up by the sweep stamp directly (not by scanning the account's
	// paid rows): exact, and immune to any per-account list bound.
	paid, err := s.billing().Store().ListStripeWithdrawalsBySweepPayoutID(pe.ID)
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
		wd.Status = "transferred"
		wd.SweepPayoutID = ""
		wd.FailureReason = "sweep_payout_failed " + pe.FailureCode + ": " + pe.FailureReason +
			" (payout " + pe.ID + "; next sweep will retry)"
		if err := s.billing().Store().UpdateStripeWithdrawal(wd); err != nil {
			s.logger.Error("stripe connect webhook: sweep bounce reopen failed",
				"error", err, "withdrawal_id", wd.ID)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		reopened++
	}
	s.logger.Warn("stripe connect webhook: sweep payout failed — will retry on next schedule",
		"stripe_account_id", pe.ConnectedAcct, "payout_id", pe.ID,
		"failure_code", pe.FailureCode, "reopened_withdrawals", reopened)
	// Partial persist failures redeliver; reopened rows drop out of the
	// "paid" list, so the retry only touches the stragglers.
	return firstErr
}
