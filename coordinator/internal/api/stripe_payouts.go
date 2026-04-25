package api

// Stripe Payouts handlers — bank/card withdrawals via Stripe Connect Express.
//
// Flow:
//
//  1. Onboard. POST /v1/billing/stripe/onboard creates a Stripe Express
//     connected account for the Privy user (idempotent — reuses an existing
//     stripe_account_id if one is on file), then returns a hosted onboarding
//     URL the frontend redirects them to.
//  2. Status. GET /v1/billing/stripe/status returns the user's current
//     readiness state. Called both on the billing page load and when the user
//     comes back from the hosted onboarding flow so we can refresh from
//     Stripe before the webhook arrives.
//  3. Withdraw. POST /v1/billing/withdraw/stripe debits the ledger by
//     amount_usd, computes the Instant fee (1.5% / $0.50 min) if requested,
//     calls transfers.create then payouts.create, and persists the local
//     withdrawal row. On any Stripe error we re-credit the ledger.
//  4. Webhook. POST /v1/billing/stripe/connect/webhook drives the local state
//     machine via account.updated, payout.paid, payout.failed, transfer.failed.
//     payout.failed and transfer.failed re-credit the user's ledger via
//     LedgerRefund.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/google/uuid"
)

// stripeStatusReady is the value of User.StripeAccountStatus when payouts are
// enabled on the Stripe side. The set of statuses tracks the StripeAccount
// lifecycle: "" (not onboarded) → "pending" (link created, not finished) →
// "ready" | "restricted" | "rejected".
const (
	stripeStatusPending    = "pending"
	stripeStatusReady      = "ready"
	stripeStatusRestricted = "restricted"
	stripeStatusRejected   = "rejected"
)

// handleStripeOnboard handles POST /v1/billing/stripe/onboard.
// Creates a Stripe Express connected account on first call (or reuses the one
// on file) and returns a hosted onboarding URL.
func (s *Server) handleStripeOnboard(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing == nil || s.billing.StripeConnect() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Stripe Payouts not configured"))
		return
	}

	// Allow the frontend to override the return URL (handy for staged envs)
	// but fall back to the coordinator-configured default.
	var req struct {
		ReturnURL  string `json:"return_url,omitempty"`
		RefreshURL string `json:"refresh_url,omitempty"`
		Country    string `json:"country,omitempty"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)

	returnURL := strings.TrimSpace(req.ReturnURL)
	if returnURL == "" {
		returnURL = s.billing.StripeConnectReturnURL()
	}
	refreshURL := strings.TrimSpace(req.RefreshURL)
	if refreshURL == "" {
		refreshURL = s.billing.StripeConnectRefreshURL()
	}
	if refreshURL == "" {
		// Sensible fallback so the link doesn't 500 if only return_url is set.
		refreshURL = returnURL
	}
	if returnURL == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"return_url is required (configure EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL or pass it in the request)"))
		return
	}

	// Validate the return/refresh URLs against the configured default's
	// origin to prevent open-redirect: a phisher could otherwise hand the
	// user a /stripe/onboard link with their own domain as return_url and
	// hijack the post-KYC flow. The allowlist is the host of the configured
	// default; localhost is also allowed for dev.
	if err := validateRedirectURL(returnURL, s.billing.StripeConnectReturnURL()); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"return_url is not allowed: "+err.Error()))
		return
	}
	if err := validateRedirectURL(refreshURL, s.billing.StripeConnectReturnURL()); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"refresh_url is not allowed: "+err.Error()))
		return
	}

	// Reuse the user's existing Stripe account if we have one. If we don't,
	// create a fresh Express account and persist the ID before we ever hand
	// the user a link — otherwise a webhook arriving before our DB write
	// could reference an unknown account.
	stripeAcctID := user.StripeAccountID
	if stripeAcctID == "" {
		acct, err := s.billing.StripeConnect().CreateExpressAccount(billing.CreateExpressAccountParams{
			Email:   user.Email,
			Country: strings.TrimSpace(req.Country),
		})
		if err != nil {
			s.logger.Error("stripe connect: create account failed", "error", err)
			writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error", err.Error()))
			return
		}
		stripeAcctID = acct.ID
		if err := s.billing.Store().SetUserStripeAccount(user.AccountID, stripeAcctID, stripeStatusPending, "", "", false); err != nil {
			s.logger.Error("stripe connect: persist account id failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to persist Stripe account"))
			return
		}
	}

	link, err := s.billing.StripeConnect().CreateAccountLink(stripeAcctID, returnURL, refreshURL)
	if err != nil {
		s.logger.Error("stripe connect: create account link failed", "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error", err.Error()))
		return
	}

	// Re-read the user — the SetUserStripeAccount above may have updated the
	// status from "" to "pending"; we want the response to reflect that.
	refreshed, err := s.billing.Store().GetUserByAccountID(user.AccountID)
	if err == nil {
		user = refreshed
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"url":               link,
		"stripe_account_id": stripeAcctID,
		"status":            user.StripeAccountStatus,
	})
}

// handleStripeStatus handles GET /v1/billing/stripe/status.
// Returns the full readiness/destination snapshot used by the billing UI to
// render the Withdraw → Bank panel.
func (s *Server) handleStripeStatus(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing == nil || s.billing.StripeConnect() == nil {
		writeJSON(w, http.StatusOK, map[string]any{"has_account": false, "configured": false})
		return
	}

	resp := map[string]any{
		"has_account":            user.StripeAccountID != "",
		"configured":             true,
		"stripe_account_id":      user.StripeAccountID,
		"status":                 user.StripeAccountStatus,
		"destination_type":       user.StripeDestinationType,
		"destination_last4":      user.StripeDestinationLast4,
		"instant_eligible":       user.StripeInstantEligible,
		"min_withdraw_micro_usd": billing.MinWithdrawMicroUSD,
		"instant_fee_bps":        billing.InstantFeeBps,
		"instant_fee_min_usd":    float64(billing.InstantFeeMinMicroUSD) / 1_000_000,
	}

	// Optional refresh=1 query param fetches the latest snapshot from Stripe
	// and rewrites our local state. The frontend hits this on return from the
	// onboarding flow so the UI doesn't lag behind the webhook.
	if user.StripeAccountID != "" && r.URL.Query().Get("refresh") == "1" {
		acct, err := s.billing.StripeConnect().GetAccount(user.StripeAccountID)
		if err != nil {
			s.logger.Warn("stripe connect: status refresh failed", "error", err)
		} else {
			status := stripeStatusForAccount(acct)
			if err := s.billing.Store().SetUserStripeAccount(user.AccountID, user.StripeAccountID,
				status, acct.DestinationType, acct.DestinationLast4, acct.InstantEligible); err != nil {
				s.logger.Warn("stripe connect: status persist failed", "error", err)
			} else {
				resp["status"] = status
				resp["destination_type"] = acct.DestinationType
				resp["destination_last4"] = acct.DestinationLast4
				resp["instant_eligible"] = acct.InstantEligible
				resp["currently_due"] = acct.CurrentlyDue
			}
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

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

	// Check withdrawable balance — only earnings can be withdrawn.
	withdrawable := s.store.GetWithdrawableBalance(user.AccountID)
	if withdrawable < grossMicroUSD {
		writeJSON(w, http.StatusBadRequest, errorResponse("insufficient_withdrawable",
			fmt.Sprintf("withdrawable balance is $%.2f (total balance may be higher but includes non-withdrawable credits)",
				float64(withdrawable)/1_000_000)))
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

	if err := s.billing.Ledger().Charge(user.AccountID, grossMicroUSD, debitRef); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("insufficient_funds", err.Error()))
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

// validateRedirectURL ensures the user-supplied URL is on the same host as
// the operator-configured default. localhost is always allowed (dev). If no
// default is configured, the URL must be https and the call rejects http.
func validateRedirectURL(candidate, defaultURL string) error {
	cu, err := url.Parse(candidate)
	if err != nil {
		return errors.New("invalid URL")
	}
	if cu.Scheme != "https" && cu.Scheme != "http" {
		return errors.New("scheme must be http or https")
	}
	host := strings.ToLower(cu.Hostname())
	if host == "localhost" || host == "127.0.0.1" || host == "::1" {
		return nil
	}
	if defaultURL == "" {
		// No allowlist configured → require https + non-empty host.
		if cu.Scheme != "https" || host == "" {
			return errors.New("must be https with a hostname when no default is configured")
		}
		return nil
	}
	du, err := url.Parse(defaultURL)
	if err != nil {
		return nil // defaults are operator-configured; if malformed, fall back to allow https
	}
	if !strings.EqualFold(cu.Hostname(), du.Hostname()) {
		return fmt.Errorf("host %q does not match allowed host %q", cu.Hostname(), du.Hostname())
	}
	return nil
}

// stripeStatusForAccount maps a fresh Stripe account snapshot onto our local
// status enum.
func stripeStatusForAccount(acct *billing.ExpressAccount) string {
	switch {
	case acct.DisabledReason != "" && strings.HasPrefix(acct.DisabledReason, "rejected"):
		return stripeStatusRejected
	case acct.PayoutsEnabled:
		return stripeStatusReady
	case acct.DetailsSubmitted && len(acct.CurrentlyDue) > 0:
		return stripeStatusRestricted
	default:
		return stripeStatusPending
	}
}

// microUSDToCents truncates to integer cents (1¢ = 10,000 micro-USD).
func microUSDToCents(microUSD int64) int64 { return microUSD / 10_000 }

func formatUSD(microUSD int64) string {
	return fmt.Sprintf("%.2f", float64(microUSD)/1_000_000)
}

func etaForMethod(method string) string {
	if method == "instant" {
		return "~30 minutes"
	}
	return "1-2 business days"
}

// Compile-time check we don't accidentally drop the auth import; the Privy
// helpers stay in scope via requirePrivyUser.
var _ = auth.UserFromContext

// Compile-time check on time import staying live.
var _ = time.Now
