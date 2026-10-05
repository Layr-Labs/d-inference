package payouts

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleStripeUnlink handles DELETE /v1/billing/stripe/account.
//
// Detaches the stored connected account from the user so the next onboard
// creates a fresh one. This is the self-serve escape hatch for wedged
// accounts (closed on Stripe's side, stuck onboarding, wrong country
// selected, wrong service agreement). It does not touch Stripe — the
// connected account (and any balance still being swept to the user's bank)
// is unaffected, and in-flight withdrawals still reconcile via webhooks
// because the rows carry their own copy of the stripe_account_id.
//
// Idempotent: unlinking with no account on file succeeds.
func (s *Owner) HandleStripeUnlink(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	if repo, ok := s.globalPayoutStore(); ok {
		if _, err := repo.GetGlobalRecipient(user.AccountID); err == nil {
			if err = repo.RemoveGlobalRecipient(user.AccountID); err != nil {
				globalPayoutError(w, err)
				return
			}
			httpx.WriteJSON(w, 200, map[string]bool{"unlinked": true})
			return
		} else if !errors.Is(err, store.ErrNotFound) {
			globalPayoutError(w, err)
			return
		}
	}
	if s.billing == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "billing not configured"))
		return
	}
	if s.billing.GlobalPayoutsOnly() {
		httpx.
			// Retain the legacy identity for old payouts. Future setup is Global Payouts.
			WriteJSON(w, http.StatusOK, map[string]bool{"unlinked": false})
		return
	}

	if user.StripeAccountID == "" {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"unlinked": false})
		return
	}
	prev := user.StripeAccountID
	if err := s.billing.Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); err != nil {
		s.logger.Error("stripe connect: unlink failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to unlink Stripe account"))
		return
	}
	s.logger.Info("stripe connect: account unlinked",
		"account", user.AccountID[:min(8, len(user.AccountID))]+"...",
		"stripe_account_id", prev)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"unlinked": true})
}
