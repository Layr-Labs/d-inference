package globalpayouts

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/url"
)

// RequiredFundingCents includes quoted Stripe charges paid by the platform.
// Decimal minor-unit fee estimates are rounded up, without floating-point math.
func RequiredFundingCents(principal int64, raw json.RawMessage) (int64, error) {
	if principal <= 0 {
		return 0, fmt.Errorf("invalid payout principal")
	}
	var fees []EstimatedFee
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &fees); err != nil {
			return 0, err
		}
	}
	total := new(big.Rat).SetInt64(principal)
	for _, fee := range fees {
		if fee.Amount.Currency != "usd" || len(fee.Amount.Value.String()) > 64 {
			return 0, fmt.Errorf("unusable payout fee estimate")
		}
		amount, ok := new(big.Rat).SetString(fee.Amount.Value.String())
		if !ok || amount.Sign() < 0 {
			return 0, fmt.Errorf("invalid payout fee estimate")
		}
		total.Add(total, amount)
	}
	whole, remainder := new(big.Int), new(big.Int)
	whole.QuoRem(total.Num(), total.Denom(), remainder)
	if remainder.Sign() > 0 {
		whole.Add(whole, big.NewInt(1))
	}
	if !whole.IsInt64() {
		return 0, fmt.Errorf("payout funding amount overflow")
	}
	return whole.Int64(), nil
}

// AvailableUSD reads the actual financial account, never the Payments balance.
func (c *Client) AvailableUSD(ctx context.Context) (int64, error) {
	var account struct {
		ID      string `json:"id"`
		Status  string `json:"status"`
		Balance struct {
			Available map[string]Amount `json:"available"`
		} `json:"balance"`
	}
	if err := c.do(ctx, "GET", "/v2/money_management/financial_accounts/"+url.PathEscape(c.FinancialAccount), "", "", nil, &account); err != nil {
		return 0, err
	}
	amount, ok := account.Balance.Available["usd"]
	if account.ID != c.FinancialAccount || account.Status != "open" || !ok || amount.Currency != "usd" {
		return 0, fmt.Errorf("payout financial account unavailable")
	}
	return amount.Value, nil
}
