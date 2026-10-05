package payouts

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/billing"
)

// handleStripeOnboard handles POST /v1/billing/stripe/onboard.
// Creates a Stripe Express connected account on first call (or reuses the one
// on file) and returns a hosted onboarding URL.
func (s *Owner) HandleStripeOnboard(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "Stripe Payouts not configured"))
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
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"return_url is required (configure EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL or pass it in the request)"))
		return
	}

	// Validate the return/refresh URLs against the configured default's
	// origin to prevent open-redirect: a phisher could otherwise hand the
	// user a /stripe/onboard link with their own domain as return_url and
	// hijack the post-KYC flow. The allowlist is the host of the configured
	// default; localhost is also allowed for dev.
	if err := validateRedirectURL(returnURL, s.billing.StripeConnectReturnURL()); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"return_url is not allowed: "+err.Error()))
		return
	}
	if err := validateRedirectURL(refreshURL, s.billing.StripeConnectReturnURL()); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"refresh_url is not allowed: "+err.Error()))
		return
	}

	// Normalize the requested country up front. Stripe Express country is
	// immutable once the account is created, so we treat the user's selection
	// as the source of truth.
	requestedCountry := strings.ToUpper(strings.TrimSpace(req.Country))
	if s.maybeGlobalOnboard(w, r, user, requestedCountry, returnURL, refreshURL) {
		return
	}
	if s.billing.StripeConnect() == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "Stripe Payouts not configured"))
		return
	}
	if requestedCountry == "" && user.StripeAccountID == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"country is required before creating a Stripe payout account"))
		return
	}

	// Decide whether the existing account (if any) is reusable. Stripe locks
	// both the country and the service agreement when the Express account is
	// created (https://docs.stripe.com/connect/accounts,
	// https://docs.stripe.com/connect/service-agreement-types), so we must
	// create a NEW account when:
	//   - the user picked a different country than their existing account,
	//   - the account no longer exists on Stripe (user closed it), or
	//   - the account is under the wrong service agreement for its country
	//     (e.g. AU/NZ/JP accounts created under `full` before we set
	//     `recipient` — those can never receive platform transfers).
	stripeAcctID := user.StripeAccountID
	needNewAccount := stripeAcctID == ""
	existingCountry := user.StripeAccountCountry

	if stripeAcctID != "" {
		countryChanged := requestedCountry != "" &&
			(user.StripeAccountCountry == "" || requestedCountry != user.StripeAccountCountry)

		acct, err := s.billing.StripeConnect().GetAccount(stripeAcctID)
		switch {
		case err != nil && billing.IsAccountGoneErr(err):
			s.logger.Warn("stripe connect: stored account gone — recreating",
				"stripe_account_id", stripeAcctID, "error", err)
			needNewAccount = true
		case err != nil:
			// Transient Stripe error — only force a new account if the user
			// explicitly changed country; otherwise proceed with the existing
			// one and let CreateAccountLink surface any real problem.
			s.logger.Warn("stripe connect: onboard account fetch failed", "error", err)
			needNewAccount = countryChanged
		default:
			if acct.Country != "" {
				existingCountry = acct.Country
			}
			required := billing.RequiredServiceAgreement(
				s.billing.StripeConnect().PlatformCountry(), acct.Country)
			have := billing.NormalizeServiceAgreement(acct.ServiceAgreement)
			agreementMismatch := have != required
			if agreementMismatch {
				s.logger.Warn("stripe connect: service agreement mismatch — recreating account",
					"stripe_account_id", stripeAcctID, "country", acct.Country,
					"have", have, "want", required)
			}
			needNewAccount = countryChanged || agreementMismatch
			if !needNewAccount && acct.PayoutInterval == "manual" {
				// Self-heal accounts created by older code with a manual
				// payout schedule (they strand transferred funds).
				if err := s.billing.StripeConnect().UpdateAccountPayoutScheduleAuto(stripeAcctID, acct.Country); err != nil {
					s.logger.Warn("stripe connect: payout schedule self-heal failed",
						"stripe_account_id", stripeAcctID, "error", err)
				} else {
					s.logger.Info("stripe connect: payout schedule healed to automatic",
						"stripe_account_id", stripeAcctID)
				}
			}
		}
	}

	if needNewAccount {
		country := requestedCountry
		if country == "" {
			country = existingCountry
		}
		if country == "" {
			country = s.billing.StripeConnect().PlatformCountry()
		}
		acct, err := s.billing.StripeConnect().CreateExpressAccount(billing.CreateExpressAccountParams{
			Email:   user.Email,
			Country: country,
		})
		if err != nil {
			s.logger.Error("stripe connect: create account failed", "error", err)
			httpx.WriteJSON(w, http.StatusBadGateway, httpx.ErrorResponse("stripe_error", err.Error()))
			return
		}
		stripeAcctID = acct.ID
		if err := s.billing.Store().SetUserStripeAccount(user.AccountID, stripeAcctID, stripeStatusPending, country, "", "", false); err != nil {
			s.logger.Error("stripe connect: persist account id failed", "error", err)
			httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to persist Stripe account"))
			return
		}
	}

	link, err := s.billing.StripeConnect().CreateAccountLink(stripeAcctID, returnURL, refreshURL)
	if err != nil {
		s.logger.Error("stripe connect: create account link failed", "error", err)
		httpx.WriteJSON(w, http.StatusBadGateway, httpx.ErrorResponse("stripe_error", err.Error()))
		return
	}

	if repo, ok := s.globalPayoutStore(); ok {
		if err := repo.RemoveGlobalRecipient(user.AccountID); err != nil {
			globalPayoutError(w, err)
			return
		}
	}

	// Re-read the user — the SetUserStripeAccount above may have updated the
	// status from "" to "pending"; we want the response to reflect that.
	refreshed, err := s.billing.Store().GetUserByAccountID(user.AccountID)
	if err == nil {
		user = refreshed
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"url":               link,
		"stripe_account_id": stripeAcctID,
		"status":            user.StripeAccountStatus,
	})
}
