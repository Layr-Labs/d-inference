package billing

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (s *Controller) globalPayoutStore() (store.GlobalPayoutStore, bool) {
	if s.billing() == nil {
		return nil, false
	}
	return store.As[store.GlobalPayoutStore](s.billing().Store())
}

func (s *Controller) payoutCountries() []globalpayouts.Country {
	if s.billing() == nil || !s.billing().GlobalPayoutsEnabled() {
		return nil
	}
	return append([]globalpayouts.Country(nil), globalpayouts.Countries...)
}

// maybeGlobalOnboard is called after validating redirects, before any Express
// account is created. Existing ready Connect destinations remain usable.
func (s *Controller) maybeGlobalOnboard(w http.ResponseWriter, r *http.Request, user *store.User, country, returnURL, refreshURL string) bool {
	repo, ok := s.globalPayoutStore()
	if !ok {
		return false
	}
	active, err := repo.GetGlobalRecipient(user.AccountID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		globalPayoutError(w, err)
		return true
	}
	if !s.billing().GlobalPayoutsEnabled() && errors.Is(err, store.ErrNotFound) {
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
	if !known || !s.billing().GlobalPayoutsEnabled() {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("country_unavailable", "Bank withdrawals are not available in this country yet. Your earnings remain in your account."))
		return true
	}
	if user.Email == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("email_required", "Add an email address to your account before setting up bank withdrawals."))
		return true
	}
	local, err := repo.PrepareGlobalRecipient(store.GlobalRecipient{ID: uuid.NewString(), AccountID: user.AccountID, Country: country})
	if err != nil {
		globalPayoutError(w, err)
		return true
	}
	client := s.billing().GlobalPayouts()
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
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"url": link, "stripe_account_id": local.RecipientID, "status": "pending", "payout_rail": "global"})
	return true
}

func (s *Controller) refreshGlobalRecipient(ctx context.Context, local *store.GlobalRecipient) error {
	client := s.billing().GlobalPayouts()
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
	updated := *local
	updated.Ready = false
	updated.PayoutMethodID = ""
	updated.Last4 = ""
	if remote.Ready(local.Country, policy.Capability) {
		method, e := client.BankMethod(ctx, remote, local.Country, policy.Currency, policy.Capability)
		if e != nil && !errors.Is(e, globalpayouts.ErrNoEligibleBankMethod) {
			return e
		}
		if e == nil {
			updated.Ready = true
			updated.PayoutMethodID = method.ID
			updated.Last4 = method.BankAccount.Last4
		}
	}
	repo, _ := s.globalPayoutStore()
	if err := repo.SaveGlobalRecipient(updated); err != nil {
		return err
	}
	*local = updated
	return nil
}

func (s *Controller) maybeGlobalStatus(w http.ResponseWriter, r *http.Request, user *store.User) bool {
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
	configured := s.billing().GlobalPayoutsEnabled()
	if configured && local.RecipientID != "" && r.URL.Query().Get("refresh") == "1" {
		if err = s.refreshGlobalRecipient(r.Context(), local); err != nil {
			s.logger.Warn("global payout recipient refresh failed", "error", err)
			globalPayoutError(w, err)
			return true
		}
	}
	status := "pending"
	if local.Ready && configured {
		status = "ready"
	}
	policy, _ := globalpayouts.Lookup(local.Country)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"account_id": user.AccountID, "configured": true, "has_account": true, "stripe_account_id": local.RecipientID, "stripe_account_country": local.Country, "status": status, "destination_type": "bank", "destination_last4": local.Last4, "instant_eligible": false, "min_withdraw_micro_usd": billingservice.MinWithdrawMicroUSD, "payout_rail": "global", "payout_currency": policy.Currency, "recipient_limits": policy.Limits(), "countries": s.payoutCountries(), "payouts_available": configured})
	return true
}
