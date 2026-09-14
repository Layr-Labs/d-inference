package billing

import (
	"strings"
)

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
