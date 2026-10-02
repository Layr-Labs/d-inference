package api

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// No storage/configuration failure during cutover may fall through to Connect.
func (s *Server) rejectUnavailableGlobalPayouts(w http.ResponseWriter) bool {
	if s.billing == nil || !s.billing.GlobalPayoutsOnly() {
		return false
	}
	writeJSON(w, http.StatusServiceUnavailable, errorResponse("payouts_paused", "Bank payouts are temporarily unavailable. Your earnings remain in your account."))
	return true
}

func (s *Server) maybeGlobalStatus(w http.ResponseWriter, r *http.Request, user *store.User) bool {
	repo, ok := s.globalPayoutStore()
	if !ok {
		return s.rejectUnavailableGlobalPayouts(w)
	}
	local, err := repo.GetGlobalRecipient(user.AccountID)
	if errors.Is(err, store.ErrNotFound) {
		if !s.billing.GlobalPayoutsOnly() {
			return false
		}
		// Read-only status: the user must start and complete their own bank setup.
		local = &store.GlobalRecipient{AccountID: user.AccountID, Country: user.StripeAccountCountry}
	} else if err != nil {
		globalPayoutError(w, err)
		return true
	}
	configured := s.billing.GlobalPayoutsEnabled()
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
	writeJSON(w, http.StatusOK, map[string]any{
		"account_id": user.AccountID, "configured": true,
		"has_account": local.RecipientID != "", "stripe_account_id": local.RecipientID,
		"stripe_account_country": local.Country, "status": status,
		"migration_required": user.StripeAccountID != "" && !local.Ready,
		"destination_type":   "bank", "destination_last4": local.Last4,
		"instant_eligible": false, "min_withdraw_micro_usd": billing.MinWithdrawMicroUSD,
		"payout_rail": "global", "payout_currency": policy.Currency,
		"recipient_limits": policy.Limits(), "countries": s.payoutCountries(),
		"payouts_available": configured,
	})
	return true
}
