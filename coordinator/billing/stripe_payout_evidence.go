package billing

import (
	"encoding/json"
	"fmt"
	"net/url"
)

// PayoutTransfers identifies transfers actually included in an automatic payout.
// Stripe's payout filter is authoritative; timestamps or matching amounts aren't.
// Unexpanded, refunded or unrelated sources never prove a withdrawal was paid.
func (c *StripeConnect) PayoutTransfers(account, payout string) (map[string]bool, error) {
	if err := validAccountID(account); err != nil {
		return nil, err
	}
	if !stripePayoutIDRe.MatchString(payout) {
		return nil, fmt.Errorf("invalid payout id")
	}
	result := map[string]bool{}
	q := url.Values{"payout": {payout}, "limit": {"100"}, "expand[]": {"data.source"}}
	for page := 0; page < 20; page++ {
		body, err := c.do("GET", "/v1/balance_transactions?"+q.Encode(), nil, "", withStripeAccount(account))
		if err != nil {
			return nil, err
		}
		var p struct {
			HasMore bool `json:"has_more"`
			Data    []struct {
				ID     string          `json:"id"`
				Amount int64           `json:"amount"`
				Source json.RawMessage `json:"source"`
			} `json:"data"`
		}
		if err := json.Unmarshal(body, &p); err != nil {
			return nil, err
		}
		for _, txn := range p.Data {
			var charge struct {
				Object         string `json:"object"`
				SourceTransfer string `json:"source_transfer"`
				Refunded       bool   `json:"refunded"`
				AmountRefunded *int64 `json:"amount_refunded"`
			}
			if json.Unmarshal(txn.Source, &charge) == nil && txn.Amount > 0 && charge.Object == "charge" && !charge.Refunded && charge.AmountRefunded != nil && *charge.AmountRefunded == 0 && charge.SourceTransfer != "" {
				result[charge.SourceTransfer] = true
			}
		}
		if !p.HasMore {
			return result, nil
		}
		if len(p.Data) == 0 || p.Data[len(p.Data)-1].ID == "" || p.Data[len(p.Data)-1].ID == q.Get("starting_after") {
			return nil, fmt.Errorf("invalid payout evidence pagination")
		}
		q.Set("starting_after", p.Data[len(p.Data)-1].ID)
	}
	return nil, fmt.Errorf("payout evidence exceeds bounded scan; manual reconciliation required")
}
