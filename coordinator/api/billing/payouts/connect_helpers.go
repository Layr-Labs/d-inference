package payouts

import (
	"errors"
	"fmt"
	"net/url"
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

// sweepDeliveryMessage is the human copy for a standard withdrawal's success
// response, honest about the country's actual sweep cadence.
func sweepDeliveryMessage(accountCountry string) string {
	if strings.EqualFold(strings.TrimSpace(accountCountry), "JP") {
		return "funds are on the way — Stripe pays out to your bank on a weekly schedule in Japan"
	}
	return "funds are on the way — Stripe pays out to your bank on a daily schedule"
}
