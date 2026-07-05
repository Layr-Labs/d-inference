package api

// Stripe Payouts handlers — bank/card withdrawals via Stripe Connect Express.
//
// Flow:
//
//  1. Onboard. POST /v1/billing/stripe/onboard creates a Stripe Express
//     connected account for the Privy user (idempotent — reuses an existing
//     stripe_account_id when it is still valid; recreates it when the user
//     changed country, closed the account on Stripe, or the account is under
//     the wrong service agreement for its country), then returns a hosted
//     onboarding URL the frontend redirects them to. Accounts outside the
//     US/CA/UK/EEA/CH transfer region are created under the `recipient`
//     service agreement (see billing/stripe_regions.go).
//  2. Status. GET /v1/billing/stripe/status returns the user's current
//     readiness state. Called both on the billing page load and when the user
//     comes back from the hosted onboarding flow so we can refresh from
//     Stripe before the webhook arrives. refresh=1 also self-heals legacy
//     manual payout schedules and unlinks accounts deleted on Stripe's side.
//  3. Withdraw. POST /v1/billing/withdraw/stripe debits the ledger by
//     amount_usd and calls transfers.create. Standard withdrawals are then
//     delivered by Stripe's automatic daily payout sweep (local currency,
//     works for recipient accounts); instant withdrawals additionally call
//     payouts.create against the user's debit card. On transfer failure we
//     re-credit the ledger.
//  4. Unlink. DELETE /v1/billing/stripe/account detaches the stored connected
//     account so the user can onboard a fresh one (support/self-serve escape
//     hatch for wedged accounts).
//  5. Webhook. POST /v1/billing/stripe/connect/webhook drives the local state
//     machine via account.updated, payout.paid, payout.failed,
//     transfer.reversed. Automatic sweep payouts (IDs we never created) are
//     matched back to withdrawal rows by connected account. Only
//     transfer.reversed re-credits the ledger — a failed payout leaves the
//     funds in the connected account where the next sweep retries delivery.

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
)

// stripeStatusReady is the value of User.StripeAccountStatus when payouts are
// enabled on the Stripe side. The set of statuses tracks the StripeAccount
// lifecycle: "" (not onboarded) → "pending" (link created, not finished) →
// "ready" | "restricted" | "rejected".
const (
	stripeStatusPending    = "pending"
	stripeStatusReady      = "ready"
	stripeStatusRestricted = "restricted"
	stripeStatusRejected   = "rejected"
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

	// Normalize the requested country up front. Stripe Express country is
	// immutable once the account is created, so we treat the user's selection
	// as the source of truth.
	requestedCountry := strings.ToUpper(strings.TrimSpace(req.Country))
	if requestedCountry == "" && user.StripeAccountID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
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
			writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error", err.Error()))
			return
		}
		stripeAcctID = acct.ID
		if err := s.billing.Store().SetUserStripeAccount(user.AccountID, stripeAcctID, stripeStatusPending, country, "", "", false); err != nil {
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
		"stripe_account_country": user.StripeAccountCountry,
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
		switch {
		case err != nil && billing.IsAccountGoneErr(err):
			// The user closed their Stripe account — unlink it so the UI
			// offers a fresh onboarding instead of a permanently broken state.
			s.logger.Warn("stripe connect: stored account gone — unlinking",
				"stripe_account_id", user.StripeAccountID, "error", err)
			if perr := s.billing.Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); perr != nil {
				s.logger.Error("stripe connect: unlink gone account failed", "error", perr)
			} else {
				// Clear EVERY account-derived field the response was
				// pre-populated with — the store no longer holds any of
				// them, and stale country/destination values would leak
				// into the fresh-onboarding UI for one page load.
				resp["has_account"] = false
				resp["stripe_account_id"] = ""
				resp["status"] = ""
				resp["stripe_account_country"] = ""
				resp["destination_type"] = ""
				resp["destination_last4"] = ""
				resp["instant_eligible"] = false
			}
		case err != nil:
			s.logger.Warn("stripe connect: status refresh failed", "error", err)
		default:
			// Self-heal accounts created by older code with a manual payout
			// schedule — a manual schedule strands transferred funds in the
			// connected account ("Contact Eigen Labs, Inc. to get paid out").
			if acct.PayoutInterval == "manual" {
				if herr := s.billing.StripeConnect().UpdateAccountPayoutScheduleAuto(user.StripeAccountID, acct.Country); herr != nil {
					s.logger.Warn("stripe connect: payout schedule self-heal failed",
						"stripe_account_id", user.StripeAccountID, "error", herr)
				} else {
					s.logger.Info("stripe connect: payout schedule healed to automatic",
						"stripe_account_id", user.StripeAccountID)
				}
			}
			status := stripeStatusForAccount(acct)
			if err := s.billing.Store().SetUserStripeAccount(user.AccountID, user.StripeAccountID,
				status, acct.Country, acct.DestinationType, acct.DestinationLast4, acct.InstantEligible); err != nil {
				s.logger.Warn("stripe connect: status persist failed", "error", err)
			} else {
				resp["status"] = status
				resp["stripe_account_country"] = acct.Country
				resp["destination_type"] = acct.DestinationType
				resp["destination_last4"] = acct.DestinationLast4
				resp["instant_eligible"] = acct.InstantEligible
				resp["currently_due"] = acct.CurrentlyDue
			}
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

// handleStripeWithdrawals handles GET /v1/billing/stripe/withdrawals.
// Returns the user's recent Stripe withdrawals for display in the UI.
func (s *Server) handleStripeWithdrawals(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	limit := 50
	if l := r.URL.Query().Get("limit"); l != "" {
		if v, err := strconv.Atoi(l); err == nil && v > 0 && v <= 200 {
			limit = v
		}
	}
	withdrawals, err := s.billing.Store().ListStripeWithdrawals(user.AccountID, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"withdrawals": withdrawals})
}

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
func (s *Server) handleStripeUnlink(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "billing not configured"))
		return
	}
	if user.StripeAccountID == "" {
		writeJSON(w, http.StatusOK, map[string]any{"unlinked": false})
		return
	}
	prev := user.StripeAccountID
	if err := s.billing.Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); err != nil {
		s.logger.Error("stripe connect: unlink failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to unlink Stripe account"))
		return
	}
	s.logger.Info("stripe connect: account unlinked",
		"account", user.AccountID[:min(8, len(user.AccountID))]+"...",
		"stripe_account_id", prev)
	writeJSON(w, http.StatusOK, map[string]any{"unlinked": true})
}

// validateRedirectURL ensures the user-supplied URL is on the same host as
// the operator-configured default. localhost is always allowed (dev). If no
// default is configured, the URL must be https and the call rejects http.
func validateRedirectURL(candidate, defaultURL string) error {
	cu, err := url.Parse(candidate)
	if err != nil {
		return errors.New("invalid URL")
	}
	if cu.Scheme != "https" && cu.Scheme != "http" {
		return errors.New("scheme must be http or https")
	}
	host := strings.ToLower(cu.Hostname())
	if host == "localhost" || host == "127.0.0.1" || host == "::1" {
		return nil
	}
	if defaultURL == "" {
		// No allowlist configured → require https + non-empty host.
		if cu.Scheme != "https" || host == "" {
			return errors.New("must be https with a hostname when no default is configured")
		}
		return nil
	}
	du, err := url.Parse(defaultURL)
	if err != nil {
		return nil // defaults are operator-configured; if malformed, fall back to allow https
	}
	if !strings.EqualFold(cu.Hostname(), du.Hostname()) {
		return fmt.Errorf("host %q does not match allowed host %q", cu.Hostname(), du.Hostname())
	}
	return nil
}

// stripeStatusForAccount maps a fresh Stripe account snapshot onto our local
// status enum.
func stripeStatusForAccount(acct *billing.ExpressAccount) string {
	switch {
	case acct.DisabledReason != "" && strings.HasPrefix(acct.DisabledReason, "rejected"):
		return stripeStatusRejected
	case acct.PayoutsEnabled:
		return stripeStatusReady
	case acct.DetailsSubmitted && len(acct.CurrentlyDue) > 0:
		return stripeStatusRestricted
	default:
		return stripeStatusPending
	}
}

// microUSDToCents truncates to integer cents (1¢ = 10,000 micro-USD).
func microUSDToCents(microUSD int64) int64 { return microUSD / 10_000 }

func formatUSD(microUSD int64) string {
	return fmt.Sprintf("%.2f", float64(microUSD)/1_000_000)
}

func etaForMethod(method, accountCountry string) string {
	if method == "instant" {
		return "~30 minutes"
	}
	// Japan has no daily automatic payouts — accounts there sweep weekly
	// (see billing.setAutoPayoutSchedule), so the honest ETA is up to a
	// week to the sweep plus the bank rail.
	if strings.EqualFold(strings.TrimSpace(accountCountry), "JP") {
		return "up to 7-10 business days (weekly payout schedule)"
	}
	// Standard: Stripe's automatic daily payout sweeps the connected balance,
	// then the bank rail (ACH/SEPA/local) takes 1-2 business days. Recipient-
	// agreement accounts add +24h of transfer availability delay.
	return "1-3 business days"
}

// Compile-time check we don't accidentally drop the auth import; the Privy
// helpers stay in scope via requirePrivyUser.
var _ = auth.UserFromContext

// Compile-time check on time import staying live.
var _ = time.Now

// sweepDeliveryMessage is the human copy for a standard withdrawal's success
// response, honest about the country's actual sweep cadence.
func sweepDeliveryMessage(accountCountry string) string {
	if strings.EqualFold(strings.TrimSpace(accountCountry), "JP") {
		return "funds are on the way — Stripe pays out to your bank on a weekly schedule in Japan"
	}
	return "funds are on the way — Stripe pays out to your bank on a daily schedule"
}
