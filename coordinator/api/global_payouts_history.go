package api

import (
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func globalWithdrawalView(p store.GlobalPayout) map[string]any {
	return map[string]any{"id": p.ID, "account_id": p.AccountID, "stripe_account_id": p.RecipientID, "payout_id": p.ExternalID, "amount_micro_usd": p.AmountMicroUSD, "net_micro_usd": p.AmountMicroUSD, "fee_micro_usd": int64(0), "method": "standard", "status": p.Status, "payout_rail": "global", "destination_amount": p.DestinationAmount, "payout_currency": p.Currency, "currency_exponent": payoutCurrencyExponent(p.Currency), "failure_reason": p.FailureCode, "refunded": p.Refunded, "created_at": p.SubmittedAt, "updated_at": p.CheckedAt}
}

func (s *Server) appendGlobalWithdrawals(accountID string, connect []store.StripeWithdrawal, limit int) ([]any, error) {
	type entry struct {
		at    time.Time
		value any
	}
	entries := make([]entry, 0, len(connect))
	for _, p := range connect {
		entries = append(entries, entry{p.CreatedAt, p})
	}
	if repo, ok := s.globalPayoutStore(); ok {
		payouts, err := repo.ListGlobalPayouts(accountID, limit)
		if err != nil {
			return nil, fmt.Errorf("list Global Payouts: %w", err)
		}
		for _, p := range payouts {
			entries = append(entries, entry{p.SubmittedAt, globalWithdrawalView(p)})
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].at.After(entries[j].at) })
	if len(entries) > limit {
		entries = entries[:limit]
	}
	out := make([]any, 0, len(entries))
	for _, e := range entries {
		out = append(out, e.value)
	}
	return out, nil
}
