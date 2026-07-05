package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// handleStripeWithdraw handles POST /v1/billing/withdraw/stripe.
//
// Body: { amount_usd: "10.00", method: "standard"|"instant" }
//
// Behavior:
//  1. Validate method + amount, then pre-validate the connected account
//     against Stripe: closed accounts are unlinked, wrong-service-agreement
//     accounts (AU/NZ/JP created under `full`) get an actionable
//     "recreate" error, and legacy manual payout schedules are healed.
//  2. Compute fee (Instant: 1.5%, $0.50 min; Standard: free).
//  3. Debit the ledger by the GROSS amount.
//  4. transfers.create — on failure the ledger is re-credited.
//     Standard: done; Stripe's automatic daily payout sweeps the connected
//     balance to the user's bank in their local currency.
//     Instant: payouts.create to the debit card; if it fails, the instant
//     fee is refunded and the daily sweep delivers via the standard rail.
//  5. Persist a stripe_withdrawals row; webhooks drive it to a terminal
//     state (payout.paid → "paid", including automatic sweep payouts).
func (s *Server) handleStripeWithdraw(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing == nil || s.billing.StripeConnect() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Stripe Payouts not configured"))
		return
	}
	if user.StripeAccountID == "" || user.StripeAccountStatus != stripeStatusReady {
		writeJSON(w, http.StatusForbidden, errorResponse("not_onboarded",
			"link your bank or debit card via Stripe before withdrawing"))
		return
	}

	var req struct {
		AmountUSD string `json:"amount_usd"`
		Method    string `json:"method"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	method := strings.ToLower(strings.TrimSpace(req.Method))
	if method == "" {
		method = "standard"
	}
	if method != "standard" && method != "instant" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"method must be 'standard' or 'instant'"))
		return
	}

	// Pre-validate the connected account against Stripe BEFORE debiting the
	// ledger. This catches accounts that are doomed to fail the transfer —
	// closed accounts and wrong-service-agreement accounts (AU/NZ/JP created
	// under `full`) — and turns them into actionable errors instead of a
	// debit/refund cycle with a cryptic Stripe message.
	acct, err := s.billing.StripeConnect().GetAccount(user.StripeAccountID)
	if err != nil {
		if billing.IsAccountGoneErr(err) {
			s.logger.Warn("stripe payout: stored account gone — unlinking",
				"stripe_account_id", user.StripeAccountID, "error", err)
			if perr := s.billing.Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); perr != nil {
				s.logger.Error("stripe payout: unlink gone account failed", "error", perr)
			}
			writeJSON(w, http.StatusConflict, errorResponse("stripe_account_gone",
				"your Stripe payout account no longer exists — set up payouts again from the billing page"))
			return
		}
		s.logger.Error("stripe payout: account pre-check failed", "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error",
			"could not verify your payout account with Stripe — try again shortly"))
		return
	}
	requiredAgreement := billing.RequiredServiceAgreement(
		s.billing.StripeConnect().PlatformCountry(), acct.Country)
	if billing.NormalizeServiceAgreement(acct.ServiceAgreement) != requiredAgreement {
		// The agreement is immutable — this account can never receive
		// transfers. Flip the local status so the UI prompts the user to
		// re-run payout setup, which recreates the account correctly.
		if perr := s.billing.Store().SetUserStripeAccount(user.AccountID, user.StripeAccountID,
			stripeStatusRestricted, acct.Country, acct.DestinationType, acct.DestinationLast4,
			acct.InstantEligible); perr != nil {
			s.logger.Error("stripe payout: persist restricted status failed", "error", perr)
		}
		s.logger.Warn("stripe payout: service agreement mismatch — user must re-onboard",
			"stripe_account_id", user.StripeAccountID, "country", acct.Country,
			"have", billing.NormalizeServiceAgreement(acct.ServiceAgreement), "want", requiredAgreement)
		writeJSON(w, http.StatusConflict, errorResponse("stripe_account_recreate_required",
			"your payout account can't receive transfers in your country — re-run payout setup from the billing page to recreate it"))
		return
	}
	if !acct.PayoutsEnabled {
		writeJSON(w, http.StatusForbidden, errorResponse("not_onboarded",
			"your Stripe account can't receive payouts yet — finish onboarding from the billing page"))
		return
	}
	if acct.PayoutInterval == "manual" {
		// Self-heal accounts created by older code: a manual schedule strands
		// transferred funds in the connected account balance forever. Delivery
		// depends entirely on the daily sweep (the instant path falls back to
		// it too), so if the heal fails we abort BEFORE the ledger debit
		// rather than park the user's money behind a schedule that never pays
		// out — the exact bug this path exists to fix.
		if herr := s.billing.StripeConnect().UpdateAccountPayoutScheduleDaily(user.StripeAccountID); herr != nil {
			s.logger.Error("stripe payout: payout schedule self-heal failed — refusing withdrawal",
				"stripe_account_id", user.StripeAccountID, "error", herr)
			writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error",
				"could not enable automatic payouts on your account — try again shortly"))
			return
		}
		s.logger.Info("stripe payout: payout schedule healed to daily",
			"stripe_account_id", user.StripeAccountID)
	}
	// Instant requires a debit-card destination. Trust either the fresh
	// snapshot or the webhook-maintained flag — if both are stale and Stripe
	// rejects the instant payout, the fallback path refunds the instant fee
	// and delivers via the standard daily sweep.
	if method == "instant" && !acct.InstantEligible && !user.StripeInstantEligible {
		writeJSON(w, http.StatusBadRequest, errorResponse("instant_unavailable",
			"instant payouts require a debit card destination — link one in Stripe to enable"))
		return
	}

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"amount_usd must be a positive number"))
		return
	}
	grossMicroUSD := int64(amountFloat * 1_000_000)
	if grossMicroUSD < billing.MinWithdrawMicroUSD {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			fmt.Sprintf("minimum withdrawal is $%.2f", float64(billing.MinWithdrawMicroUSD)/1_000_000)))
		return
	}

	feeMicroUSD := billing.FeeForMethodMicroUSD(method, grossMicroUSD)
	netMicroUSD := grossMicroUSD - feeMicroUSD
	if netMicroUSD <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			fmt.Sprintf("amount after fees must be > $0 (fee is $%.2f)", float64(feeMicroUSD)/1_000_000)))
		return
	}

	// Cents-rounded amounts crossing the Stripe boundary. We never refund
	// sub-cent dust to the user — the gross debit absorbs any rounding so
	// the platform's books stay balanced.
	netCents := microUSDToCents(netMicroUSD)
	if netCents <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"net amount rounds to less than 1 cent"))
		return
	}

	// State machine:
	//
	//   pending     → row persisted, ledger debited, no Stripe call yet.
	//   transferred → transfer succeeded; payout may or may not be created.
	//   paid        → payout.paid webhook delivered.
	//   failed      → terminal failure; ledger refunded if Refunded=true.
	//
	// We persist the row BEFORE any Stripe call so a DB write failure can
	// never coexist with a successful money movement (no double-spend window).
	withdrawalID := uuid.New().String()
	debitRef := "stripe_withdraw:" + withdrawalID

	wd := &store.StripeWithdrawal{
		ID:              withdrawalID,
		AccountID:       user.AccountID,
		StripeAccountID: user.StripeAccountID,
		AmountMicroUSD:  grossMicroUSD,
		FeeMicroUSD:     feeMicroUSD,
		NetMicroUSD:     netMicroUSD,
		Method:          method,
		Status:          "pending",
	}
	// One store transaction debits both balance columns (preventing the
	// inflation bug where a plain Debit eats non-withdrawable credits and a
	// refund restores them as withdrawable) AND inserts the withdrawal row —
	// either both happen or neither. A crash here can no longer leave a
	// debited balance with no withdrawal row.
	if err := s.billing.Store().CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, debitRef); err != nil {
		if errors.Is(err, store.ErrInsufficientBalance) {
			writeJSON(w, http.StatusBadRequest, errorResponse("insufficient_withdrawable",
				"insufficient withdrawable balance — only earned funds can be withdrawn"))
			return
		}
		s.logger.Error("stripe payout: debit+persist withdrawal failed", "error", err, "withdrawal_id", withdrawalID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error",
			"could not start the withdrawal — nothing was debited; try again shortly"))
		return
	}

	// markFailedRefund refunds the ledger and marks the row failed
	// (best-effort — neither store call has rollback). Returns whether the
	// refund credit is durably applied; the Refunded flag prevents webhook
	// replay from double-crediting.
	markFailedRefund := func(reason string) bool {
		refunded := s.creditRefundOnceWithRetry(user.AccountID, grossMicroUSD, debitRef, withdrawalID)
		if refunded {
			wd.Refunded = true
		}
		wd.Status = "failed"
		wd.FailureReason = reason
		if uerr := s.persistWithdrawalUpdate(wd, "failure"); uerr != nil {
			s.logger.Error("stripe payout: mark failed failed", "error", uerr, "withdrawal_id", withdrawalID)
		}
		return refunded
	}

	// Step 2: transfer USD from platform balance to the connected account.
	// Retried through retryAmbiguousStripe: the idempotency key makes a
	// replay after a transport blip return the original transfer instead of
	// creating a second one.
	transfer, err := retryAmbiguousStripe(func() (*billing.Transfer, error) {
		return s.billing.StripeConnect().CreateTransfer(billing.CreateTransferParams{
			DestinationAccountID: user.StripeAccountID,
			AmountCents:          netCents,
			IdempotencyKey:       "wd-tr-" + withdrawalID,
			Description:          "Darkbloom credit withdrawal",
		})
	})
	if err != nil && !billing.IsDefinitiveAPIErr(err) {
		// AMBIGUOUS outcome: Stripe never answered, so the idempotent
		// request may have been accepted with the response lost. If it was,
		// the daily sweep will still deliver the money — refunding here
		// would pay the user twice. Park the row in "pending" (no refund):
		// if the transfer landed, ops sees the stuck-pending reconciler
		// alert and completes the row from the Stripe dashboard via the
		// idempotency key; if it didn't, the same alert drives the refund.
		wd.FailureReason = "transfer_create_unconfirmed: " + err.Error()
		if uerr := s.persistWithdrawalUpdate(wd, "ambiguous transfer"); uerr != nil {
			s.logger.Error("stripe payout: persist ambiguous-transfer state failed",
				"error", uerr, "withdrawal_id", withdrawalID)
		}
		s.logger.Error("stripe payout: transfer outcome UNCONFIRMED — no refund issued, verify against Stripe dashboard",
			"error", err, "withdrawal_id", withdrawalID, "idempotency_key", "wd-tr-"+withdrawalID)
		writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error",
			"we couldn't confirm the transfer with Stripe — your withdrawal is on hold and nothing was refunded; it will complete or be resolved automatically, contact support if it doesn't update within 24 hours"))
		return
	}
	if err != nil {
		refunded := markFailedRefund("transfer_create_failed: " + err.Error())
		s.logger.Error("stripe payout: transfer failed", "error", err, "withdrawal_id", withdrawalID)
		refundNote := "your balance was refunded"
		if !refunded {
			refundNote = "the refund to your balance is pending — contact support if it doesn't appear shortly"
		}

		// Classify permanent account problems (races with the pre-check) so
		// the user gets an actionable error instead of a raw Stripe message.
		switch {
		case billing.IsAccountGoneErr(err):
			if perr := s.billing.Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); perr != nil {
				s.logger.Error("stripe payout: unlink gone account failed", "error", perr)
			}
			writeJSON(w, http.StatusConflict, errorResponse("stripe_account_gone",
				"your Stripe payout account no longer exists — "+refundNote+"; set up payouts again from the billing page"))
		case billing.IsServiceAgreementErr(err):
			if perr := s.billing.Store().SetUserStripeAccount(user.AccountID, user.StripeAccountID,
				stripeStatusRestricted, "", "", "", false); perr != nil {
				s.logger.Error("stripe payout: persist restricted status failed", "error", perr)
			}
			writeJSON(w, http.StatusConflict, errorResponse("stripe_account_recreate_required",
				"your payout account can't receive transfers in your country — "+refundNote+"; re-run payout setup from the billing page to recreate it"))
		default:
			writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error",
				"failed to transfer funds ("+refundNote+"): "+err.Error()))
		}
		return
	}
	wd.TransferID = transfer.ID
	wd.Status = "transferred"
	if err := s.persistWithdrawalUpdate(wd, "transfer_id"); err != nil {
		// Transfer succeeded but we lost track of it: the row is stuck
		// "pending" with no transfer_id, invisible to the webhook matcher and
		// sweep reconciler. Money is in the connected account and the daily
		// auto-payout still delivers it — don't refund (double-credit). The
		// reconciler's stale-pending alert surfaces the row for ops.
		s.logger.Error("stripe payout: persist transfer_id failed after retries — row stuck pending, funds deliver via sweep",
			"error", err, "withdrawal_id", withdrawalID, "transfer_id", transfer.ID)
	}

	// Step 3 (standard): nothing to do. The connected account is on Stripe's
	// automatic daily payout schedule, which sweeps the balance to the user's
	// bank in their local currency. We deliberately do NOT create a manual
	// payout here: manual payouts require the balance to already be available
	// (transfers to `recipient` accounts take +24h) and must be denominated in
	// the connected account's settlement currency — Stripe converts cross-
	// border transfers, so a hardcoded USD payout fails for any non-USD
	// account. The sweep handles both; the payout.paid webhook marks the row.
	if method == "standard" {
		s.logger.Info("stripe payout: transferred (auto-payout will deliver)",
			"withdrawal_id", withdrawalID,
			"account", user.AccountID[:min(8, len(user.AccountID))]+"...",
			"gross_micro_usd", grossMicroUSD,
			"net_micro_usd", netMicroUSD,
		)
		writeJSON(w, http.StatusOK, map[string]any{
			"status":            "transferred",
			"withdrawal_id":     withdrawalID,
			"transfer_id":       transfer.ID,
			"amount_usd":        formatUSD(grossMicroUSD),
			"fee_usd":           formatUSD(feeMicroUSD),
			"net_usd":           formatUSD(netMicroUSD),
			"method":            method,
			"eta":               etaForMethod(method),
			"message":           "funds are on the way — Stripe pays out to your bank on a daily schedule",
			"balance_micro_usd": s.billing.Ledger().Balance(user.AccountID),
		})
		return
	}

	// Step 3 (instant): create the Stripe Instant Payout from the connected
	// account to the user's debit card. Instant payouts are USD/debit-card
	// only, which the InstantEligible gate above guarantees. Idempotent —
	// ambiguous transport failures are retried with the same key.
	payout, err := retryAmbiguousStripe(func() (*billing.Payout, error) {
		return s.billing.StripeConnect().CreatePayout(billing.CreatePayoutParams{
			OnBehalfOfAccountID: user.StripeAccountID,
			AmountCents:         netCents,
			Method:              method,
			IdempotencyKey:      "wd-po-" + withdrawalID,
			Description:         "Darkbloom credit withdrawal",
		})
	})
	if err != nil && !billing.IsDefinitiveAPIErr(err) {
		// AMBIGUOUS outcome: the payout may exist with its ID lost in
		// flight. If it does, the user IS getting instant delivery — so do
		// NOT refund the instant fee, and don't guess a terminal state. The
		// row keeps its transfer and no payout ID; if the payout landed,
		// its paid webhook won't match (unmatched non-automatic payouts are
		// ignored) and no sweep will fire on the emptied balance, so the
		// 48h reconciler alert surfaces the row for ops to settle via the
		// idempotency key. If it didn't land, the daily sweep delivers and
		// completes the row; ops refunds the fee from the same alert trail.
		wd.FailureReason = "instant_payout_unconfirmed: " + err.Error()
		if uerr := s.persistWithdrawalUpdate(wd, "ambiguous payout"); uerr != nil {
			s.logger.Error("stripe payout: persist ambiguous-payout state failed",
				"error", uerr, "withdrawal_id", withdrawalID)
		}
		s.logger.Error("stripe payout: instant payout outcome UNCONFIRMED — fee NOT refunded, verify against Stripe dashboard",
			"error", err, "withdrawal_id", withdrawalID, "transfer_id", transfer.ID,
			"idempotency_key", "wd-po-"+withdrawalID)
		writeJSON(w, http.StatusAccepted, map[string]any{
			"status":            "transferred",
			"withdrawal_id":     withdrawalID,
			"transfer_id":       transfer.ID,
			"amount_usd":        formatUSD(grossMicroUSD),
			"fee_usd":           formatUSD(feeMicroUSD),
			"net_usd":           formatUSD(netMicroUSD),
			"method":            method,
			"message":           "we couldn't confirm your instant payout with Stripe — if it went through, funds reach your card in ~30 minutes; otherwise the daily payout delivers them and support will refund the instant fee, contact support if nothing arrives within 24 hours",
			"balance_micro_usd": s.billing.Ledger().Balance(user.AccountID),
		})
		return
	}
	if err != nil {
		// Transfer succeeded — funds are in the connected account and the
		// daily auto-payout will deliver them via the standard rail. We do
		// NOT refund the principal (that would double-credit), but we DO
		// refund the instant fee: the user isn't getting instant delivery.
		wd.FailureReason = "instant_payout_create_failed: " + err.Error()
		// Reference-idempotent: shares its ledger ref with the webhook
		// fee-refund path, so no interleaving pays the fee twice — a later
		// transfer.reversed re-checks the same reference.
		feeRefunded := feeMicroUSD == 0
		if feeMicroUSD > 0 &&
			s.creditRefundOnceWithRetry(user.AccountID, feeMicroUSD, "stripe_withdraw_fee:"+withdrawalID, withdrawalID) {
			feeRefunded = true
			wd.FeeRefunded = true
			wd.FailureReason += " (instant fee refunded)"
		}
		if uerr := s.persistWithdrawalUpdate(wd, "payout failure"); uerr != nil {
			s.logger.Error("stripe payout: persist payout failure failed",
				"error", uerr, "withdrawal_id", withdrawalID)
		}
		s.logger.Error("stripe payout: create instant payout failed", "error", err,
			"withdrawal_id", withdrawalID, "transfer_id", transfer.ID)
		msg := "instant payout unavailable — the fee was refunded and funds will arrive via the standard daily payout"
		if !feeRefunded {
			msg = "instant payout unavailable — funds will arrive via the standard daily payout; the instant-fee refund is pending, contact support if it doesn't appear shortly"
		}
		writeJSON(w, http.StatusAccepted, map[string]any{
			"status":            "transferred",
			"withdrawal_id":     withdrawalID,
			"transfer_id":       transfer.ID,
			"amount_usd":        formatUSD(grossMicroUSD),
			"fee_usd":           formatUSD(feeMicroUSD),
			"net_usd":           formatUSD(netMicroUSD),
			"method":            method,
			"message":           msg,
			"balance_micro_usd": s.billing.Ledger().Balance(user.AccountID),
		})
		return
	}
	wd.PayoutID = payout.ID
	if err := s.persistWithdrawalUpdate(wd, "payout_id"); err != nil {
		// Payout succeeded but we couldn't persist the ID. Webhook will
		// arrive with the payout ID — without the index entry the sweep
		// matcher will still reconcile it by connected account. Log loudly
		// so ops can double-check via the Stripe dashboard.
		s.logger.Error("stripe payout: persist payout_id failed after retries",
			"error", err, "withdrawal_id", withdrawalID,
			"transfer_id", transfer.ID, "payout_id", payout.ID)
	}

	s.logger.Info("stripe payout: created",
		"withdrawal_id", withdrawalID,
		"account", user.AccountID[:min(8, len(user.AccountID))]+"...",
		"method", method,
		"gross_micro_usd", grossMicroUSD,
		"fee_micro_usd", feeMicroUSD,
		"net_micro_usd", netMicroUSD,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":            "submitted",
		"withdrawal_id":     withdrawalID,
		"transfer_id":       transfer.ID,
		"payout_id":         payout.ID,
		"amount_usd":        formatUSD(grossMicroUSD),
		"fee_usd":           formatUSD(feeMicroUSD),
		"net_usd":           formatUSD(netMicroUSD),
		"method":            method,
		"eta":               etaForMethod(method),
		"arrival_unix":      payout.ArrivalDate,
		"balance_micro_usd": s.billing.Ledger().Balance(user.AccountID),
	})
}

// retryAmbiguousStripe retries fn while it fails with a non-definitive error
// (transport timeout, connection drop, lost response) — outcomes where an
// idempotency-keyed Stripe request may have been accepted. Replaying with the
// same key returns the original result instead of moving money twice, so the
// retry either recovers the lost response or surfaces Stripe's definitive
// rejection. Definitive API errors return immediately. Bounded at 3 attempts
// (0/200/400ms backoff), same budget as the other in-request retries.
func retryAmbiguousStripe[T any](fn func() (T, error)) (T, error) {
	out, err := fn()
	for attempt := 1; attempt <= 2 && err != nil && !billing.IsDefinitiveAPIErr(err); attempt++ {
		time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		out, err = fn()
	}
	return out, err
}

// creditRefundOnceWithRetry credits a reference-idempotent refund, riding out
// transient store blips with short retries (safe: duplicates are deduped on
// the ledger reference). Returns whether the credit is durably applied.
//
// The retries deliberately ignore the request context and run to completion:
// they only execute AFTER money has moved (or a debit landed), and a client
// disconnect must not abandon the user's refund. Worst case is bounded at
// 600ms of backoff (3 attempts × 0/200/400ms).
func (s *Server) creditRefundOnceWithRetry(accountID string, amountMicroUSD int64, ref, withdrawalID string) bool {
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		}
		_, err := s.billing.Store().CreditWithdrawableOnce(accountID, amountMicroUSD, store.LedgerRefund, ref)
		if err == nil {
			return true
		}
		s.logger.Warn("stripe payout: refund credit attempt failed",
			"attempt", attempt+1, "error", err, "withdrawal_id", withdrawalID, "ledger_ref", ref)
	}
	s.logger.Error("stripe payout: refund credit failed after retries — MANUAL CREDIT REQUIRED",
		"withdrawal_id", withdrawalID, "ledger_ref", ref, "amount_micro_usd", amountMicroUSD)
	return false
}

// persistWithdrawalUpdate retries a withdrawal-row update with short backoff.
// Used after money has moved (transfer/payout created): losing the update
// strands the row in a state the webhook matcher and sweep reconciler don't
// look at, so it's worth riding out a transient store blip in-request. Like
// creditRefundOnceWithRetry, it deliberately ignores request-context
// cancellation (bounded at 600ms total backoff) — abandoning the persist on
// client disconnect is exactly how rows get orphaned.
func (s *Server) persistWithdrawalUpdate(wd *store.StripeWithdrawal, stage string) error {
	var err error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		}
		if err = s.billing.Store().UpdateStripeWithdrawal(wd); err == nil {
			return nil
		}
		s.logger.Warn("stripe payout: persist "+stage+" attempt failed",
			"attempt", attempt+1, "error", err, "withdrawal_id", wd.ID)
	}
	return err
}
