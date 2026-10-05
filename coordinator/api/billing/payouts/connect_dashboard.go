package payouts

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleStripeDashboardLink handles POST /v1/billing/stripe/dashboard.
//
// Mints a single-use Stripe Express Dashboard login link for the caller's
// connected account. That dashboard is where the user changes the bank account
// or debit card their payouts land in, reviews their connected balance, and
// sees Stripe's own payout history — none of which we rebuild ourselves.
//
// It is the only way an already-onboarded Express account can edit its payout
// destination: handleStripeOnboard's `account_onboarding` link collects
// outstanding requirements only (a ready account has none), and Stripe rejects
// `account_update` links for accounts that have a Stripe-hosted dashboard,
// which every Express account does.
//
// Wired behind requirePrivyAuth for the same reason as unlink, only more so:
// the URL this returns is a bearer credential for a session that can redirect
// the user's earnings to a different bank account. A leaked inference API key
// must not be able to mint one.
func (s *Owner) HandleStripeDashboardLink(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing == nil || s.billing.StripeConnect() == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "Stripe Payouts not configured"))
		return
	}
	if s.billing.GlobalPayoutsOnly() {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("bank_setup_required", "Manage your bank details through bank payout setup."))
		return
	}
	if repo, ok := s.globalPayoutStore(); ok {
		if _, err := repo.GetGlobalRecipient(user.AccountID); !errors.Is(err, store.ErrNotFound) {
			if err != nil {
				globalPayoutError(w, err)
			} else {
				httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("bank_setup_required", "Manage your bank details through bank payout setup."))
			}
			return
		}
	}

	if user.StripeAccountID == "" || !stripeDashboardAvailable(user.StripeAccountStatus) {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("not_onboarded",
			"finish your payout setup first, then you can manage the account in Stripe"))
		return
	}

	link, err := s.billing.StripeConnect().CreateLoginLink(user.StripeAccountID)
	if err != nil {
		if billing.IsAccountGoneErr(err) {
			// Closed on Stripe's side — unlink so the UI falls back to
			// onboarding instead of offering a permanently broken button
			// (same self-heal as the refresh=1 path in handleStripeStatus).
			s.logger.Warn("stripe connect: stored account gone — unlinking",
				"stripe_account_id", user.StripeAccountID, "error", err)
			if perr := s.billing.Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); perr != nil {
				// Don't claim an unlink we failed to persist — the UI would
				// tell the user to set payouts up again while still showing
				// the old account.
				s.logger.Error("stripe connect: unlink gone account failed", "error", perr)
				httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error",
					"failed to unlink your closed Stripe account"))
				return
			}
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("stripe_account_gone",
				"your Stripe account no longer exists — set up payouts again"))
			return
		}
		s.logger.Error("stripe connect: create login link failed",
			"stripe_account_id", user.StripeAccountID, "error", err)
		httpx.WriteJSON(w, http.StatusBadGateway, httpx.ErrorResponse("stripe_error", err.Error()))
		return
	}

	// Log the issuance, never the link — it is a live credential.
	s.logger.Info("stripe connect: express dashboard link issued",
		"account", user.AccountID[:min(8, len(user.AccountID))]+"...",
		"stripe_account_id", user.StripeAccountID)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"url":               link,
		"stripe_account_id": user.StripeAccountID,
	})
}
