package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
)

func TestGlobalPayoutRecipientLimits(t *testing.T) {
	cases := []struct {
		name, country, amount, quoteError, want string
		rate                                    int64
		calls                                   int
	}{
		{"usd-floor-before-stripe", "PA", "5", "", "50.00 USD", 1, 0},
		{"usd-other-floor", "SV", "5", "", "30.00 USD", 1, 0},
		{"fx-floor-from-quote", "TW", "5", "", "800.00 TWD", 30, 1},
		{"fx-floor-stripe-rejection", "TW", "5", "amount_too_small_for_payout_method", "800.00 TWD", 30, 1},
		{"fx-ceiling", "PE", "90000", "", "310000.00 PEN", 4, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, st, u, f := globalPayoutAPIFixture(t, false)
			policy, _ := globalpayouts.Lookup(tc.country)
			f.country = strings.ToLower(tc.country)
			f.currency = policy.Currency
			f.rate = tc.rate
			f.quoteError = tc.quoteError
			w := globalAPIRequest(t, s, u, "/onboard", `{"country":"`+tc.country+`"}`, s.handleStripeOnboard)
			if w.Code != 200 {
				t.Fatal(w.Body.String())
			}
			w = globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"`+tc.amount+`"}`, s.handleGlobalPayoutQuote)
			if w.Code != 400 || !strings.Contains(w.Body.String(), tc.want) || f.quoteCalls != tc.calls || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
				t.Fatalf("limit not actionable or moved funds: %d %s calls=%d", w.Code, w.Body.String(), f.quoteCalls)
			}
			w = globalAPIRequest(t, s, u, "/status", ``, s.handleStripeStatus)
			if !strings.Contains(w.Body.String(), "recipient_limits") {
				t.Fatal("limits missing before review")
			}
		})
	}
}

func TestGlobalPayoutQuoteRetainsStripeFeeEstimate(t *testing.T) {
	s, st, u, _, id := newConfigChangeQuote(t, false)
	p, _ := st.GetGlobalPayout(id)
	var fees []globalpayouts.EstimatedFee
	if err := json.Unmarshal(p.EstimatedStripeFees, &fees); err != nil || len(fees) != 1 || fees[0].Amount.Value.String() != "150" {
		t.Fatalf("fee estimate lost: %s %v", p.EstimatedStripeFees, err)
	}
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
	if !strings.Contains(w.Body.String(), `"fee_usd":"0.00"`) {
		t.Fatal("platform fee was charged to provider")
	}
}
