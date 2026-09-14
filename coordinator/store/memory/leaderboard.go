package memory

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// Leaderboard ranks accounts by the chosen metric, splitting inference work from
// network rewards. Base-reward rows live in provider_earnings for provider-facing
// history, but count as reward earnings here so they do not inflate work/jobs.
// Reward-only ledger accounts (e.g. consumer-only referrers) do not appear.
func (s *Store) Leaderboard(metric contracts.LeaderboardMetric, since time.Time, limit int) []contracts.LeaderboardRow {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	agg := make(map[string]*contracts.LeaderboardRow)
	rowFor := func(accountID string) *contracts.LeaderboardRow {
		row, ok := agg[accountID]
		if !ok {
			row = &contracts.LeaderboardRow{AccountID: accountID}
			agg[accountID] = row
		}
		return row
	}
	// Provider earnings rows: inference work plus base_reward rows.
	for _, e := range s.providerEarnings {
		if e.AccountID == "" {
			continue
		}
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		row := rowFor(e.AccountID)
		if e.Model == "base_reward" {
			row.RewardEarningsMicroUSD += e.AmountMicroUSD
			continue
		}
		row.WorkEarningsMicroUSD += e.AmountMicroUSD
		row.Tokens += int64(e.PromptTokens + e.CompletionTokens)
		row.Jobs++
	}
	// Non-inference reward earnings — credited only to provider accounts (those
	// that already have inference work above). Reward-only accounts (e.g.
	// consumer-only referrers) are intentionally not added to the provider
	// leaderboard.
	for _, e := range s.ledgerEntries {
		if e.AccountID == "" || !contracts.IsRewardLedgerType(e.Type) {
			continue
		}
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		if row, ok := agg[e.AccountID]; ok {
			row.RewardEarningsMicroUSD += e.AmountMicroUSD
		}
	}
	rows := make([]contracts.LeaderboardRow, 0, len(agg))
	for _, r := range agg {
		r.EarningsMicroUSD = r.WorkEarningsMicroUSD + r.RewardEarningsMicroUSD
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		switch metric {
		case contracts.LeaderboardTokens:
			if rows[i].Tokens != rows[j].Tokens {
				return rows[i].Tokens > rows[j].Tokens
			}
		case contracts.LeaderboardJobs:
			if rows[i].Jobs != rows[j].Jobs {
				return rows[i].Jobs > rows[j].Jobs
			}
		default:
			if rows[i].EarningsMicroUSD != rows[j].EarningsMicroUSD {
				return rows[i].EarningsMicroUSD > rows[j].EarningsMicroUSD
			}
		}
		return rows[i].AccountID < rows[j].AccountID
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows
}

// NetworkTotals aggregates provider earnings, splitting inference work from
// rewards. Base-reward rows count as reward earnings, not work/jobs/tokens.
// Ledger rewards are only counted for accounts that also have provider earnings
// rows in the window, so consumer-only reward recipients do not inflate totals.
func (s *Store) NetworkTotals(since time.Time) (contracts.NetworkTotalsRow, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var t contracts.NetworkTotalsRow
	providers := make(map[string]struct{})
	for _, e := range s.providerEarnings {
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		if e.AccountID != "" {
			providers[e.AccountID] = struct{}{}
		}
		if e.Model == "base_reward" {
			t.RewardEarningsMicroUSD += e.AmountMicroUSD
			continue
		}
		t.WorkEarningsMicroUSD += e.AmountMicroUSD
		t.Tokens += int64(e.PromptTokens + e.CompletionTokens)
		t.Jobs++
	}
	for _, e := range s.ledgerEntries {
		if !contracts.IsRewardLedgerType(e.Type) {
			continue
		}
		if !since.IsZero() && e.CreatedAt.Before(since) {
			continue
		}
		if _, ok := providers[e.AccountID]; ok {
			t.RewardEarningsMicroUSD += e.AmountMicroUSD
		}
	}
	t.EarningsMicroUSD = t.WorkEarningsMicroUSD + t.RewardEarningsMicroUSD
	t.ActiveAccounts = int64(len(providers))
	return t, nil
}
