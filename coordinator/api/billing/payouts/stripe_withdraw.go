package payouts

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
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
//  4. transfers.create — low platform funding queues the reserved amount;
//     other definitive failures re-credit the ledger.
//     Standard: done; Stripe's automatic daily payout sweeps the connected
//     balance to the user's bank in their local currency.
//     Instant: payouts.create to the debit card; if it fails, the instant
//     fee is refunded and the daily sweep delivers via the standard rail.
//  5. Persist a stripe_withdrawals row; webhooks drive it to a terminal
//     state (payout.paid → "paid", including automatic sweep payouts).
func (s *Owner) HandleStripeWithdraw(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "Stripe Payouts not configured"))
		return
	}
	if s.maybeGlobalWithdraw(w, r, user) {
		return
	}
	if s.billing.StripeConnect() == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "Stripe Payouts not configured"))
		return
	}
	if user.StripeAccountID == "" || user.StripeAccountStatus != stripeStatusReady {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("not_onboarded",
			"link your bank or debit card via Stripe before withdrawing"))
		return
	}

	var req struct {
		AmountUSD string `json:"amount_usd"`
		Method    string `json:"method"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	method := strings.ToLower(strings.TrimSpace(req.Method))
	if method == "" {
		method = "standard"
	}
	if method != "standard" && method != "instant" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
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
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("stripe_account_gone",
				"your Stripe payout account no longer exists — set up payouts again from the billing page"))
			return
		}
		s.logger.Error("stripe payout: account pre-check failed", "error", err)
		httpx.WriteJSON(w, http.StatusBadGateway, httpx.ErrorResponse("stripe_error",
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
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("stripe_account_recreate_required",
			"your payout account can't receive transfers in your country — re-run payout setup from the billing page to recreate it"))
		return
	}
	if !acct.PayoutsEnabled {
		// Persist the fresh (non-ready) snapshot so the UI's status refresh
		// reflects reality — otherwise the card keeps showing "Ready" while
		// withdrawals 403, with no visible path to fix the account.
		if perr := s.billing.Store().SetUserStripeAccount(user.AccountID, user.StripeAccountID,
			stripeStatusForAccount(acct), acct.Country, acct.DestinationType, acct.DestinationLast4,
			acct.InstantEligible); perr != nil {
			s.logger.Error("stripe payout: persist disabled status failed", "error", perr)
		}
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("not_onboarded",
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
		if herr := s.billing.StripeConnect().UpdateAccountPayoutScheduleAuto(user.StripeAccountID, acct.Country); herr != nil {
			s.logger.Error("stripe payout: payout schedule self-heal failed — refusing withdrawal",
				"stripe_account_id", user.StripeAccountID, "error", herr)
			httpx.WriteJSON(w, http.StatusBadGateway, httpx.ErrorResponse("stripe_error",
				"could not enable automatic payouts on your account — try again shortly"))
			return
		}
		s.logger.Info("stripe payout: payout schedule healed to automatic",
			"stripe_account_id", user.StripeAccountID)
	}
	// Instant requires a debit-card destination. Trust either the fresh
	// snapshot or the webhook-maintained flag — if both are stale and Stripe
	// rejects the instant payout, the fallback path refunds the instant fee
	// and delivers via the standard daily sweep.
	if method == "instant" && !acct.InstantEligible && !user.StripeInstantEligible {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("instant_unavailable",
			"instant payouts require a debit card destination — link one in Stripe to enable"))
		return
	}

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"amount_usd must be a positive number"))
		return
	}
	grossMicroUSD := int64(amountFloat * 1_000_000)
	if grossMicroUSD < billing.MinWithdrawMicroUSD {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			fmt.Sprintf("minimum withdrawal is $%.2f", float64(billing.MinWithdrawMicroUSD)/1_000_000)))
		return
	}

	feeMicroUSD := billing.FeeForMethodMicroUSD(method, grossMicroUSD)
	netMicroUSD := grossMicroUSD - feeMicroUSD
	if netMicroUSD <= 0 {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			fmt.Sprintf("amount after fees must be > $0 (fee is $%.2f)", float64(feeMicroUSD)/1_000_000)))
		return
	}

	// Cents-rounded amounts crossing the Stripe boundary. We never refund
	// sub-cent dust to the user — the gross debit absorbs any rounding so
	// the platform's books stay balanced.
	netCents := microUSDToCents(netMicroUSD)
	if netCents <= 0 {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
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
		ID:                withdrawalID,
		AccountID:         user.AccountID,
		StripeAccountID:   user.StripeAccountID,
		AmountMicroUSD:    grossMicroUSD,
		FeeMicroUSD:       feeMicroUSD,
		NetMicroUSD:       netMicroUSD,
		Method:            method,
		Status:            "pending",
		TransferStartedAt: time.Now(),
	}
	// One store transaction debits both balance columns (preventing the
	// inflation bug where a plain Debit eats non-withdrawable credits and a
	// refund restores them as withdrawable) AND inserts the withdrawal row —
	// either both happen or neither. A crash here can no longer leave a
	// debited balance with no withdrawal row.
	if err := s.billing.Store().CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, debitRef); err != nil {
		if errors.Is(err, store.ErrInsufficientBalance) {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("insufficient_withdrawable",
				"insufficient withdrawable balance — only earned funds can be withdrawn"))
			return
		}
		s.logger.Error("stripe payout: debit+persist withdrawal failed", "error", err, "withdrawal_id", withdrawalID)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error",
			"could not start the withdrawal — nothing was debited; try again shortly"))
		return
	}

	result := s.dispatchStripeWithdrawal(wd, acct.Country)
	httpx.WriteJSON(w, result.status, result.body)
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
	ambiguous := err != nil && !billing.IsDefinitiveAPIErr(err)
	for attempt := 1; attempt <= 2 && err != nil && !billing.IsDefinitiveAPIErr(err); attempt++ {
		time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		out, err = fn()
	}
	if ambiguous && err != nil && billing.IsDefinitiveAPIErr(err) {
		// A later authorization/validation failure cannot disprove an earlier
		// accepted request whose response was lost. Deliberately don't unwrap.
		err = fmt.Errorf("earlier Stripe attempt unconfirmed; subsequent response: %v", err)
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
func (s *Owner) creditRefundOnceWithRetry(accountID string, amountMicroUSD int64, ref, withdrawalID string) bool {
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
func (s *Owner) persistWithdrawalUpdate(wd *store.StripeWithdrawal, stage string) error {
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
