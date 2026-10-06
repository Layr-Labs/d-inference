package payouts

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/billing"
)

// handleStripeStatus handles GET /v1/billing/stripe/status.
// Returns the full readiness/destination snapshot used by the billing UI to
// render the Withdraw → Bank panel.
func (s *Owner) HandleStripeStatus(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	if s.billing == nil {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"has_account": false, "configured": false})
		return
	}

	if s.maybeGlobalStatus(w, r, user) {
		return
	}
	if s.billing.StripeConnect() == nil {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"has_account": false, "configured": false})
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
	httpx.WriteJSON(w, http.StatusOK, resp)
}
