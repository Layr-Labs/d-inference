package payouts

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	amountformat "github.com/eigeninference/d-inference/coordinator/internal/billing/amount"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func payoutCurrencyExponent(currency string) int { return globalpayouts.CurrencyExponent(currency) }

func (s *Owner) HandleGlobalPayoutQuote(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	repo, ok := s.globalPayoutStore()
	if !ok || !s.billing.GlobalPayoutsEnabled() {
		globalPayoutError(w, errors.New("Global Payouts unavailable"))
		return
	}
	var req struct {
		Amount string `json:"amount_usd"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req) != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "Enter a valid withdrawal amount."))
		return
	}
	cents, err := amountformat.PayoutUSDCents(req.Amount)
	if err != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}
	local, err := repo.GetGlobalRecipient(user.AccountID)
	if err != nil {
		globalPayoutError(w, err)
		return
	}
	if err = s.refreshGlobalRecipient(r.Context(), local); err != nil {
		globalPayoutError(w, err)
		return
	}
	if !local.Ready {
		httpx.WriteJSON(w, 409, httpx.ErrorResponse("not_onboarded", "Complete your bank details in Stripe before withdrawing."))
		return
	}
	policy, _ := globalpayouts.Lookup(local.Country)
	// The input is USD. Only USD destination bounds can be compared before FX.
	if policy.Currency == "usd" {
		if err := policy.ValidateRecipientAmount(globalpayouts.Amount{Value: cents, Currency: "usd"}); err != nil {
			globalPayoutError(w, err)
			return
		}
	}
	request := globalpayouts.NewRequest(s.billing.GlobalPayouts().FinancialAccount, local.RecipientID, local.PayoutMethodID, policy.Currency, cents)
	quote, err := s.billing.GlobalPayouts().Quote(r.Context(), request)
	if err != nil {
		s.logger.Warn("global payout quote failed", "error", err)
		var stripeErr *globalpayouts.Error
		if errors.As(err, &stripeErr) {
			var limitErr error
			if strings.HasPrefix(stripeErr.Code, "amount_too_small") {
				limitErr = policy.LimitError(true)
			}
			if strings.HasPrefix(stripeErr.Code, "amount_too_large") {
				limitErr = policy.LimitError(false)
			}
			if limitErr != nil {
				err = limitErr
			}
		}
		globalPayoutError(w, err)
		return
	}
	if err = quote.Validate(request); err != nil {
		globalPayoutError(w, err)
		return
	}
	if err := policy.ValidateRecipientAmount(quote.To.Credited); err != nil {
		globalPayoutError(w, err)
		return
	}
	now := time.Now()
	expires := now.Add(2 * time.Minute)
	if quote.FXQuote != nil && !quote.FXQuote.LockExpiresAt.IsZero() && quote.FXQuote.LockExpiresAt.Before(expires) {
		expires = quote.FXQuote.LockExpiresAt
	}
	if !expires.After(now.Add(5 * time.Second)) {
		globalPayoutError(w, store.ErrPayoutQuoteExpired)
		return
	}
	id := uuid.NewString()
	request.QuoteID = quote.ID
	request.Description = "Darkbloom earnings"
	request.Metadata = map[string]string{"darkbloom_withdrawal_id": id}
	payload, err := json.Marshal(request)
	if err != nil {
		globalPayoutError(w, err)
		return
	}
	fees, err := json.Marshal(quote.EstimatedFees)
	if err != nil {
		globalPayoutError(w, err)
		return
	}
	p := store.GlobalPayout{EstimatedStripeFees: fees, ID: id, AccountID: user.AccountID, RecipientID: local.RecipientID, RecipientGeneration: local.ID, PayoutMethodID: local.PayoutMethodID, Country: local.Country, AmountMicroUSD: cents * 10_000, DestinationAmount: quote.To.Credited.Value, Currency: quote.To.Credited.Currency, Request: payload, Status: "quoted", ExpiresAt: expires, CreatedAt: now}
	if err = repo.CreateGlobalPayoutQuote(p); err != nil {
		globalPayoutError(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"id": id, "amount_usd": formatUSD(p.AmountMicroUSD), "fee_usd": "0.00", "destination_amount": p.DestinationAmount, "currency": p.Currency, "currency_exponent": payoutCurrencyExponent(p.Currency), "expires_at": expires, "destination_last4": local.Last4, "eta": "Typically 1–7 business days"})
}

func (s *Owner) maybeGlobalWithdraw(w http.ResponseWriter, r *http.Request, user *store.User) bool {
	repo, ok := s.globalPayoutStore()
	if !ok {
		return s.rejectUnavailableGlobalPayouts(w)
	}
	// Inspect once and restore the body for the Connect handler. A Global
	// confirmation must remain on its original rail even after unlink/country changes.
	body, readErr := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
	if readErr != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "Invalid withdrawal request."))
		return true
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	var req struct {
		Amount  string `json:"amount_usd"`
		Method  string `json:"method"`
		QuoteID string `json:"quote_id"`
	}
	decodeErr := json.Unmarshal(body, &req)
	local, err := repo.GetGlobalRecipient(user.AccountID)
	if errors.Is(err, store.ErrNotFound) && req.QuoteID == "" {
		if s.billing.GlobalPayoutsOnly() {
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("bank_setup_required", "Update your bank details before withdrawing. Your earnings are unchanged."))
			return true
		}
		return false
	}
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		globalPayoutError(w, err)
		return true
	}
	if s.billing.GlobalPayouts() == nil {
		globalPayoutError(w, errors.New("Global Payouts unavailable"))
		return true
	}
	if decodeErr != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "Invalid withdrawal request."))
		return true
	}
	cents, err := amountformat.PayoutUSDCents(req.Amount)
	if err != nil || req.QuoteID == "" || (req.Method != "" && req.Method != "standard") {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("quote_required", "Review your bank withdrawal before confirming."))
		return true
	}
	p, err := repo.GetGlobalPayout(req.QuoteID)
	if err != nil || p.AccountID != user.AccountID || p.AmountMicroUSD != cents*10_000 {
		httpx.WriteJSON(w, 409, httpx.ErrorResponse("quote_required", "Review your bank withdrawal again."))
		return true
	}
	if p.Status == "quoted" {
		var original globalpayouts.PaymentRequest
		if err := json.Unmarshal(p.Request, &original); err != nil {
			globalPayoutError(w, err)
			return true
		}
		paused := !s.billing.GlobalPayoutsEnabled()
		changed := original.From["financial_account"] != s.billing.GlobalPayouts().FinancialAccount
		if paused || changed {
			// Serialize invalidation with Begin: never clear a saved client
			// identity based on a stale "quoted" snapshot after another debit.
			p, err = repo.ExpireGlobalPayoutQuote(user.AccountID, p.ID, time.Now())
			if err != nil {
				globalPayoutError(w, err)
				return true
			}
			if p.Status == "quoted" {
				code, message := "payout_changed", "Payout settings changed. Review a new withdrawal."
				if paused {
					code, message = "quote_paused", "New bank withdrawals are paused. Your unsubmitted confirmation has been released."
				}
				httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse(code, message))
				return true
			}
		}
	}
	if p.Status == "quoted" {
		if local == nil {
			globalPayoutError(w, store.ErrPayoutConflict)
			return true
		}
		if err = s.refreshGlobalRecipient(r.Context(), local); err != nil {
			globalPayoutError(w, err)
			return true
		}
		p, err = repo.BeginGlobalPayout(user.AccountID, p.ID, time.Now())
		if err != nil {
			globalPayoutError(w, err)
			return true
		}
	}
	// A lost HTTP response can be retried using the same quote ID without a
	// second ledger debit or a new Stripe idempotency key.
	if err = s.syncGlobalPayout(r.Context(), p.ID); err != nil {
		s.logger.Error("global payout reconciliation pending", "withdrawal_id", p.ID, "error", err)
	}
	latest, err := repo.GetGlobalPayout(p.ID)
	if err == nil {
		p = latest
	}
	response := map[string]any{"status": p.Status, "withdrawal_id": p.ID, "payout_id": p.ExternalID, "amount_usd": formatUSD(p.AmountMicroUSD), "fee_usd": "0.00", "net_usd": formatUSD(p.AmountMicroUSD), "method": "standard", "payout_rail": "global", "destination_amount": p.DestinationAmount, "payout_currency": p.Currency, "refunded": p.Refunded, "balance_micro_usd": s.billing.Ledger().Balance(user.AccountID)}
	if p.Status == "queued" {
		response["message"] = "Your withdrawal is queued until payout funding is available. Your earnings are reserved; no need to submit it again."
	} else if p.Status == "pending" && !p.Refunded {
		response["message"] = "Your withdrawal is awaiting confirmation. Your earnings are reserved; track this withdrawal before submitting another."
	} else if p.ExternalID != "" && (p.Status == "processing" || p.Status == "posted") {
		response["eta"] = "Typically 1–7 business days"
	}
	httpx.WriteJSON(w, http.StatusAccepted, response)
	return true
}
