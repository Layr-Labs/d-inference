package api

import (
	"strings"

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
