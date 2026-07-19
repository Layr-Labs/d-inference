package api

import (
	"encoding/json"
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

	acct, payoutErr := s.validateStripePayoutAccount(user, method)
	if payoutErr != nil {
		writeStripeTransferError(w, payoutErr)
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

	withdrawalID := uuid.New().String()
	transferResult, payoutErr := s.executeStripeTransfer(stripeTransferRequest{
		User:            user,
		GrossMicroUSD:   grossMicroUSD,
		FeeMicroUSD:     feeMicroUSD,
		Method:          method,
		Source:          store.StripeWithdrawalSourceManual,
		WithdrawalID:    withdrawalID,
		TransferMessage: "Darkbloom credit withdrawal",
	})
	if payoutErr != nil {
		writeStripeTransferError(w, payoutErr)
		return
	}
	if transferResult == nil || transferResult.Withdrawal == nil || transferResult.Transfer == nil {
		s.logger.Error("stripe payout: transfer returned incomplete result", "withdrawal_id", withdrawalID)
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "withdrawal transfer state is incomplete"))
		return
	}
	wd := transferResult.Withdrawal
	transfer := transferResult.Transfer

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
			"eta":               etaForMethod(method, acct.Country),
			"message":           sweepDeliveryMessage(acct.Country),
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
		"eta":               etaForMethod(method, acct.Country),
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
		var applied bool
		applied, err = s.billing.Store().UpdateStripeWithdrawalIfActive(wd)
		if err == nil {
			if applied {
				return nil
			}
			return store.ErrStripeWithdrawalStateChanged
		}
		s.logger.Warn("stripe payout: persist "+stage+" attempt failed",
			"attempt", attempt+1, "error", err, "withdrawal_id", wd.ID)
	}
	return err
}
