package billing

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// StripeDashboardLink handles POST /v1/billing/stripe/dashboard.
//
// Mints a single-use Stripe Express Dashboard login link for the caller's
// connected account. That dashboard is where the user changes the bank account
// or debit card their payouts land in, reviews their connected balance, and
// sees Stripe's own payout history — none of which we rebuild ourselves.
//
// It is the only way an already-onboarded Express account can edit its payout
// destination: StripeOnboard's `account_onboarding` link collects
// outstanding requirements only (a ready account has none), and Stripe rejects
// `account_update` links for accounts that have a Stripe-hosted dashboard,
// which every Express account does.
//
// Wired behind requirePrivyAuth for the same reason as unlink, only more so:
// the URL this returns is a bearer credential for a session that can redirect
// the user's earnings to a different bank account. A leaked inference API key
// must not be able to mint one.
func (s *Controller) StripeDashboardLink(w http.ResponseWriter, r *http.Request) {
	user := requestauth.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing() == nil || s.billing().StripeConnect() == nil {
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("billing_error", "Stripe Payouts not configured"))
		return
	}
	if user.StripeAccountID == "" || !stripeDashboardAvailable(user.StripeAccountStatus) {
		httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("not_onboarded",
			"finish your payout setup first, then you can manage the account in Stripe"))
		return
	}

	link, err := s.billing().StripeConnect().CreateLoginLink(user.StripeAccountID)
	if err != nil {
		if billingservice.IsAccountGoneErr(err) {
			// Closed on Stripe's side — unlink so the UI falls back to
			// onboarding instead of offering a permanently broken button
			// (same self-heal as the refresh=1 path in StripeStatus).
			s.logger.Warn("stripe connect: stored account gone — unlinking",
				"stripe_account_id", user.StripeAccountID, "error", err)
			if perr := s.billing().Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); perr != nil {
				// Don't claim an unlink we failed to persist — the UI would
				// tell the user to set payouts up again while still showing
				// the old account.
				s.logger.Error("stripe connect: unlink gone account failed", "error", perr)
				httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error",
					"failed to unlink your closed Stripe account"))
				return
			}
			httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("stripe_account_gone",
				"your Stripe account no longer exists — set up payouts again"))
			return
		}
		s.logger.Error("stripe connect: create login link failed",
			"stripe_account_id", user.StripeAccountID, "error", err)
		httpresponse.WriteJSON(w, http.StatusBadGateway, httpresponse.ErrorBody("stripe_error", err.Error()))
		return
	}

	// Log the issuance, never the link — it is a live credential.
	s.logger.Info("stripe connect: express dashboard link issued",
		"account", user.AccountID[:min(8, len(user.AccountID))]+"...",
		"stripe_account_id", user.StripeAccountID)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"url":               link,
		"stripe_account_id": user.StripeAccountID,
	})
}

// StripeUnlink handles DELETE /v1/billing/stripe/account.
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
func (s *Controller) StripeUnlink(w http.ResponseWriter, r *http.Request) {
	user := requestauth.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	if repo, ok := s.globalPayoutStore(); ok {
		if _, err := repo.GetGlobalRecipient(user.AccountID); err == nil {
			if err = repo.RemoveGlobalRecipient(user.AccountID); err != nil {
				globalPayoutError(w, err)
				return
			}
			httpresponse.WriteJSON(w, 200, map[string]bool{"unlinked": true})
			return
		} else if !errors.Is(err, store.ErrNotFound) {
			globalPayoutError(w, err)
			return
		}
	}
	if s.billing() == nil {
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("billing_error", "billing not configured"))
		return
	}
	if user.StripeAccountID == "" {
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"unlinked": false})
		return
	}
	prev := user.StripeAccountID
	if err := s.billing().Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); err != nil {
		s.logger.Error("stripe connect: unlink failed", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to unlink Stripe account"))
		return
	}
	s.logger.Info("stripe connect: account unlinked",
		"account", user.AccountID[:min(8, len(user.AccountID))]+"...",
		"stripe_account_id", prev)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"unlinked": true})
}
