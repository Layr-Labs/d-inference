package api

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// handleStripeWithdraw handles POST /v1/billing/withdraw/stripe.
//
// Body: { amount_usd: "10.00", method: "standard"|"instant" }
//
// Behavior:
//  1. Validate method, amount, and that the user's account is ready.
//  2. Compute fee (Instant: 1.5%, $0.50 min; Standard: free).
//  3. Debit the ledger by the GROSS amount.
//  4. transfers.create → payouts.create. Any failure re-credits the ledger.
//  5. Persist a stripe_withdrawals row in "transferred" or "paid"-leaning
//     state; the webhook will eventually drive it to a terminal state.
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
	if !decodeJSONBody(w, r, &req) {
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
	if method == "instant" && !user.StripeInstantEligible {
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
	grossMicroUSD := payments.USDToMicro(amountFloat)
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

	// DebitWithdrawable atomically checks and subtracts from both
	// balance_micro_usd and withdrawable_micro_usd. This prevents the
	// inflation bug where Debit eats non-withdrawable credits and a
	// subsequent refund via CreditWithdrawable restores the amount as
	// withdrawable earnings.
	if err := s.store.DebitWithdrawable(user.AccountID, grossMicroUSD, store.LedgerStripePayout, debitRef); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("insufficient_withdrawable", err.Error()))
		return
	}

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
	if err := s.billing.Store().CreateStripeWithdrawal(wd); err != nil {
		// No Stripe calls yet — refund and bail.
		if rerr := s.billing.Store().CreditWithdrawable(user.AccountID, grossMicroUSD, store.LedgerRefund, debitRef); rerr != nil {
			s.logger.Error("stripe payout: refund after persist failure failed",
				"error", rerr, "withdrawal_id", withdrawalID)
		}
		s.logger.Error("stripe payout: persist withdrawal failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error",
			"failed to record withdrawal — refunded to your balance"))
		return
	}

	markFailedRefund := func(reason string) {
		// Refund the ledger and mark the row failed atomically (best-effort —
		// neither store call has rollback). Refunded flag prevents webhook
		// replay from double-crediting.
		if rerr := s.billing.Store().CreditWithdrawable(user.AccountID, grossMicroUSD, store.LedgerRefund, debitRef); rerr != nil {
			s.logger.Error("stripe payout: refund failed", "error", rerr, "withdrawal_id", withdrawalID)
		} else {
			wd.Refunded = true
		}
		wd.Status = "failed"
		wd.FailureReason = reason
		if uerr := s.billing.Store().UpdateStripeWithdrawal(wd); uerr != nil {
			s.logger.Error("stripe payout: mark failed failed", "error", uerr, "withdrawal_id", withdrawalID)
		}
	}

	// Step 2: transfer USD from platform balance to the connected account.
	transfer, err := s.billing.StripeConnect().CreateTransfer(billing.CreateTransferParams{
		DestinationAccountID: user.StripeAccountID,
		AmountCents:          netCents,
		IdempotencyKey:       "wd-tr-" + withdrawalID,
		Description:          "Darkbloom credit withdrawal",
	})
	if err != nil {
		markFailedRefund("transfer_create_failed: " + err.Error())
		s.logger.Error("stripe payout: transfer failed", "error", err, "withdrawal_id", withdrawalID)
		writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error",
			"failed to transfer funds: "+err.Error()))
		return
	}
	wd.TransferID = transfer.ID
	wd.Status = "transferred"
	if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
		// Transfer succeeded but we lost track of it. Money is in the
		// connected account; auto-payout will move it. Don't refund — that
		// would double-credit the user.
		s.logger.Error("stripe payout: persist transfer_id failed",
			"error", err, "withdrawal_id", withdrawalID, "transfer_id", transfer.ID)
	}

	// Step 3: create the Stripe payout from the connected account → bank/card.
	payout, err := s.billing.StripeConnect().CreatePayout(billing.CreatePayoutParams{
		OnBehalfOfAccountID: user.StripeAccountID,
		AmountCents:         netCents,
		Method:              method,
		IdempotencyKey:      "wd-po-" + withdrawalID,
		Description:         "Darkbloom credit withdrawal",
	})
	if err != nil {
		// Transfer succeeded — funds are in the connected account. Stripe's
		// default daily auto-payout schedule will move them to the bank. We
		// do NOT refund (that would double-credit) and we do NOT mark the row
		// failed (the user will eventually get the money). Leave status at
		// "transferred" with FailureReason populated for ops visibility.
		wd.FailureReason = "payout_create_failed: " + err.Error()
		if uerr := s.billing.Store().UpdateStripeWithdrawal(wd); uerr != nil {
			s.logger.Error("stripe payout: persist payout failure failed",
				"error", uerr, "withdrawal_id", withdrawalID)
		}
		s.logger.Error("stripe payout: create payout failed", "error", err,
			"withdrawal_id", withdrawalID, "transfer_id", transfer.ID)
		writeJSON(w, http.StatusAccepted, map[string]any{
			"status":            "transferred",
			"withdrawal_id":     withdrawalID,
			"transfer_id":       transfer.ID,
			"amount_usd":        formatUSD(grossMicroUSD),
			"fee_usd":           formatUSD(feeMicroUSD),
			"net_usd":           formatUSD(netMicroUSD),
			"method":            method,
			"message":           "transfer succeeded but payout failed; funds will arrive on Stripe's default schedule",
			"balance_micro_usd": s.billing.Ledger().Balance(user.AccountID),
		})
		return
	}
	wd.PayoutID = payout.ID
	if err := s.billing.Store().UpdateStripeWithdrawal(wd); err != nil {
		// Payout succeeded but we couldn't persist the ID. Webhook will
		// arrive with the payout ID — without the index entry we'll silently
		// drop it. Log loudly so ops can manually reconcile via the Stripe
		// dashboard. Do NOT refund — the user is getting the money.
		s.logger.Error("stripe payout: persist payout_id failed — webhook will be lost",
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

// handleStripeWithdrawals handles GET /v1/billing/stripe/withdrawals.
// Returns the user's recent Stripe withdrawals for display in the UI.
func (s *Server) handleStripeWithdrawals(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	limit := 50
	if l := r.URL.Query().Get("limit"); l != "" {
		if v, err := strconv.Atoi(l); err == nil && v > 0 && v <= 200 {
			limit = v
		}
	}
	withdrawals, err := s.billing.Store().ListStripeWithdrawals(user.AccountID, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"withdrawals": withdrawals})
}
