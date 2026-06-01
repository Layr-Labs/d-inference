package api

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/billing"
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
		country := strings.ToUpper(strings.TrimSpace(req.Country))
		if country == "" {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				"country is required before creating a Stripe payout account"))
			return
		}
		acct, err := s.billing.StripeConnect().CreateExpressAccount(billing.CreateExpressAccountParams{
			Email:   user.Email,
			Country: country,
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
