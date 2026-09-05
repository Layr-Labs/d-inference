package api

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (s *Server) globalPayoutStore() (store.GlobalPayoutStore, bool) {
	if s.billing == nil {
		return nil, false
	}
	return store.As[store.GlobalPayoutStore](s.billing.Store())
}
func (s *Server) payoutCountries() []globalpayouts.Country {
	if s.billing == nil || s.billing.GlobalPayouts() == nil {
		return nil
	}
	out := []globalpayouts.Country{}
	for _, c := range globalpayouts.Countries {
		if c.Rail == "connect" || (s.billing != nil && s.billing.GlobalPayoutsEnabled()) {
			out = append(out, c)
		}
	}
	return out
}
func globalPayoutError(w http.ResponseWriter, err error) {
	code, message, status := "payout_unavailable", "Bank withdrawals are temporarily unavailable. Please try again shortly.", http.StatusBadGateway
	var stripeErr *globalpayouts.Error
	if errors.As(err, &stripeErr) {
		switch stripeErr.Code {
		case "amount_too_small_for_payout_method", "amount_too_small_for_selected_delivery_option":
			code, message, status = "invalid_request_error", "This bank transfer requires a larger withdrawal amount.", http.StatusBadRequest
		case "amount_too_large_for_payout_method", "amount_too_large_for_selected_delivery_option":
			code, message, status = "invalid_request_error", "This bank transfer exceeds the withdrawal limit. Try a smaller amount.", http.StatusBadRequest
		case "fx_quote_expired":
			code, message, status = "quote_expired", "The exchange quote expired. Review your withdrawal again.", http.StatusConflict
		case "outbound_flow_unsupported_country", "recipient_feature_not_active", "payout_method_disabled", "payout_method_archived":
			code, message, status = "not_onboarded", "Your bank account needs attention. Update your payout details in Stripe.", http.StatusConflict
		}
	}
	if errors.Is(err, store.ErrInsufficientBalance) {
		code, message, status = "insufficient_withdrawable", "Only available earned funds can be withdrawn.", http.StatusBadRequest
	}
	if errors.Is(err, store.ErrPayoutQuoteExpired) {
		code, message, status = "quote_expired", "The exchange quote expired. Review your withdrawal again.", http.StatusConflict
	}
	if errors.Is(err, store.ErrPayoutConflict) {
		code, message, status = "payout_changed", "Your payout details changed. Review your withdrawal again.", http.StatusConflict
	}
	writeJSON(w, status, errorResponse(code, message))
}

// maybeGlobalOnboard is called after validating redirects, before any Express
// account is created. Existing ready Connect destinations remain usable.
func (s *Server) maybeGlobalOnboard(w http.ResponseWriter, r *http.Request, user *store.User, country, returnURL, refreshURL string) bool {
	repo, ok := s.globalPayoutStore()
	if !ok {
		return false
	}
	active, err := repo.GetGlobalRecipient(user.AccountID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		globalPayoutError(w, err)
		return true
	}
	if s.billing.GlobalPayouts() == nil && errors.Is(err, store.ErrNotFound) {
		return false
	}
	if country == "" && err == nil {
		country = active.Country
	}
	if country == "" {
		return false
	} // existing Connect onboarding handles default/required country
	policy, known := globalpayouts.Lookup(country)
	legacyReady := user.StripeAccountID != "" && user.StripeAccountStatus == stripeStatusReady && user.StripeAccountCountry == country && errors.Is(err, store.ErrNotFound)
	if legacyReady || (known && policy.Rail == "connect") {
		return false
	}
	if !known || !s.billing.GlobalPayoutsEnabled() {
		writeJSON(w, http.StatusBadRequest, errorResponse("country_unavailable", "Bank withdrawals are not available in this country yet. Your earnings remain in your account."))
		return true
	}
	if user.Email == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("email_required", "Add an email address to your account before setting up bank withdrawals."))
		return true
	}
	local, err := repo.PrepareGlobalRecipient(store.GlobalRecipient{ID: uuid.NewString(), AccountID: user.AccountID, Country: country})
	if err != nil {
		globalPayoutError(w, err)
		return true
	}
	client := s.billing.GlobalPayouts()
	if local.RecipientID == "" {
		remote, e := client.CreateRecipient(r.Context(), user.Email, country, policy.Capability, "gp-recipient-"+local.ID)
		if e != nil {
			s.logger.Warn("global payout recipient create failed", "error", e)
			globalPayoutError(w, e)
			return true
		}
		if remote.ID == "" || !strings.EqualFold(remote.Identity.Country, country) {
			globalPayoutError(w, store.ErrPayoutConflict)
			return true
		}
		local.RecipientID = remote.ID
		if e = repo.SaveGlobalRecipient(*local); e != nil {
			globalPayoutError(w, e)
			return true
		}
	}
	link, err := client.OnboardingLink(r.Context(), local.RecipientID, returnURL, refreshURL)
	if err != nil {
		s.logger.Warn("global payout onboarding link failed", "error", err)
		globalPayoutError(w, err)
		return true
	}
	writeJSON(w, http.StatusOK, map[string]any{"url": link, "stripe_account_id": local.RecipientID, "status": "pending", "payout_rail": "global"})
	return true
}

func (s *Server) refreshGlobalRecipient(ctx context.Context, local *store.GlobalRecipient) error {
	client := s.billing.GlobalPayouts()
	if client == nil {
		return errors.New("Global Payouts is disabled")
	}
	policy, ok := globalpayouts.Lookup(local.Country)
	if !ok || policy.Capability == "" {
		return store.ErrPayoutConflict
	}
	remote, err := client.Recipient(ctx, local.RecipientID)
	if err != nil {
		return err
	}
	local.Ready = false
	local.PayoutMethodID = ""
	local.Last4 = ""
	if remote.Ready(local.Country, policy.Capability) {
		method, e := client.BankMethod(ctx, remote, local.Country, policy.Currency, policy.Capability)
		if e == nil {
			local.Ready = true
			local.PayoutMethodID = method.ID
			local.Last4 = method.BankAccount.Last4
		}
	}
	repo, _ := s.globalPayoutStore()
	return repo.SaveGlobalRecipient(*local)
}

func (s *Server) maybeGlobalStatus(w http.ResponseWriter, r *http.Request, user *store.User) bool {
	repo, ok := s.globalPayoutStore()
	if !ok {
		return false
	}
	local, err := repo.GetGlobalRecipient(user.AccountID)
	if errors.Is(err, store.ErrNotFound) {
		return false
	}
	if err != nil {
		globalPayoutError(w, err)
		return true
	}
	configured := s.billing.GlobalPayoutsEnabled()
	if configured && local.RecipientID != "" && r.URL.Query().Get("refresh") == "1" {
		if err = s.refreshGlobalRecipient(r.Context(), local); err != nil {
			s.logger.Warn("global payout recipient refresh failed", "error", err)
			local.Ready = false
		}
	}
	status := "pending"
	if local.Ready && configured {
		status = "ready"
	}
	policy, _ := globalpayouts.Lookup(local.Country)
	writeJSON(w, http.StatusOK, map[string]any{"configured": true, "has_account": true, "stripe_account_id": local.RecipientID, "stripe_account_country": local.Country, "status": status, "destination_type": "bank", "destination_last4": local.Last4, "instant_eligible": false, "min_withdraw_micro_usd": billing.MinWithdrawMicroUSD, "payout_rail": "global", "payout_currency": policy.Currency, "countries": s.payoutCountries(), "payouts_available": configured})
	return true
}
