package billing

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (s *Controller) GlobalPayoutQuote(w http.ResponseWriter, r *http.Request) {
	user := requestauth.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	repo, ok := s.globalPayoutStore()
	if !ok || !s.billing().GlobalPayoutsEnabled() {
		globalPayoutError(w, errors.New("Global Payouts unavailable"))
		return
	}
	var req struct {
		Amount string `json:"amount_usd"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req) != nil {
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_request_error", "Enter a valid withdrawal amount."))
		return
	}
	cents, err := payoutUSDCents(req.Amount)
	if err != nil {
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_request_error", err.Error()))
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
		httpresponse.WriteJSON(w, 409, httpresponse.ErrorBody("not_onboarded", "Complete your bank details in Stripe before withdrawing."))
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
	request := globalpayouts.NewRequest(s.billing().GlobalPayouts().FinancialAccount, local.RecipientID, local.PayoutMethodID, policy.Currency, cents)
	quote, err := s.billing().GlobalPayouts().Quote(r.Context(), request)
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
	httpresponse.WriteJSON(w, 200, map[string]any{"id": id, "amount_usd": formatUSD(p.AmountMicroUSD), "fee_usd": "0.00", "destination_amount": p.DestinationAmount, "currency": p.Currency, "currency_exponent": payoutCurrencyExponent(p.Currency), "expires_at": expires, "destination_last4": local.Last4, "eta": "Typically 1–7 business days"})
}
