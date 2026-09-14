package billing

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
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

// StripeStatus handles GET /v1/billing/stripe/status.
// Returns the full readiness/destination snapshot used by the billing UI to
// render the Withdraw → Bank panel.
func (s *Controller) StripeStatus(w http.ResponseWriter, r *http.Request) {
	user := requestauth.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing() == nil || s.billing().StripeConnect() == nil {
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"has_account": false, "configured": false})
		return
	}

	if s.maybeGlobalStatus(w, r, user) {
		return
	}
	resp := map[string]any{
		"account_id":             user.AccountID,
		"payout_rail":            "connect",
		"countries":              s.payoutCountries(),
		"has_account":            user.StripeAccountID != "",
		"configured":             true,
		"stripe_account_id":      user.StripeAccountID,
		"status":                 user.StripeAccountStatus,
		"stripe_account_country": user.StripeAccountCountry,
		"destination_type":       user.StripeDestinationType,
		"destination_last4":      user.StripeDestinationLast4,
		"instant_eligible":       user.StripeInstantEligible,
		"min_withdraw_micro_usd": billingservice.MinWithdrawMicroUSD,
		"instant_fee_bps":        billingservice.InstantFeeBps,
		"instant_fee_min_usd":    float64(billingservice.InstantFeeMinMicroUSD) / 1_000_000,
	}

	// Optional refresh=1 query param fetches the latest snapshot from Stripe
	// and rewrites our local state. The frontend hits this on return from the
	// onboarding flow so the UI doesn't lag behind the webhook.
	if user.StripeAccountID != "" && r.URL.Query().Get("refresh") == "1" {
		acct, err := s.billing().StripeConnect().GetAccount(user.StripeAccountID)
		switch {
		case err != nil && billingservice.IsAccountGoneErr(err):
			// The user closed their Stripe account — unlink it so the UI
			// offers a fresh onboarding instead of a permanently broken state.
			s.logger.Warn("stripe connect: stored account gone — unlinking",
				"stripe_account_id", user.StripeAccountID, "error", err)
			if perr := s.billing().Store().SetUserStripeAccount(user.AccountID, "", "", "", "", "", false); perr != nil {
				s.logger.Error("stripe connect: unlink gone account failed", "error", perr)
			} else {
				resp["has_account"] = false
				resp["stripe_account_id"] = ""
				resp["status"] = ""
			}
		case err != nil:
			s.logger.Warn("stripe connect: status refresh failed", "error", err)
		default:
			// Self-heal accounts created by older code with a manual payout
			// schedule — a manual schedule strands transferred funds in the
			// connected account ("Contact Eigen Labs, Inc. to get paid out").
			if acct.PayoutInterval == "manual" {
				if herr := s.billing().StripeConnect().UpdateAccountPayoutScheduleAuto(user.StripeAccountID, acct.Country); herr != nil {
					s.logger.Warn("stripe connect: payout schedule self-heal failed",
						"stripe_account_id", user.StripeAccountID, "error", herr)
				} else {
					s.logger.Info("stripe connect: payout schedule healed to automatic",
						"stripe_account_id", user.StripeAccountID)
				}
			}
			status := stripeStatusForAccount(acct)
			if err := s.billing().Store().SetUserStripeAccount(user.AccountID, user.StripeAccountID,
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

	httpresponse.WriteJSON(w, http.StatusOK, resp)
}

// stripeDashboardAvailable reports whether an account in the given local
// status has an Express Dashboard to log in to. Stripe only issues login
// links once the account has submitted its details, so the pre-submission
// states ("" and pending) have nothing to log in to. Restricted and rejected
// accounts DO have one — that's where Stripe explains what went wrong and
// lets them fix it.
func stripeDashboardAvailable(status string) bool {
	switch status {
	case stripeStatusReady, stripeStatusRestricted, stripeStatusRejected:
		return true
	default:
		return false
	}
}

// stripeStatusForAccount maps a fresh Stripe account snapshot onto our local
// status enum.
func stripeStatusForAccount(acct *billingservice.ExpressAccount) string {
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
