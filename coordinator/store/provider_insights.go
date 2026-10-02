package store

import (
	"context"
	"fmt"
	"sort"
	"time"
)

// ProviderInsightsReader is an optional, read-only account analytics capability.
// Use As to discover it through store decorators. No ledger mutations occur.
type ProviderInsightsReader interface {
	ProviderInsightGroups(context.Context, string, time.Time, time.Time) ([]ProviderInsightGroup, error)
}

type ProviderInsightAmounts struct {
	WorkMicroUSD       int64 `json:"work_micro_usd"`
	BaseRewardMicroUSD int64 `json:"base_reward_micro_usd"`
	Jobs               int64 `json:"jobs"`
	PromptTokens       int64 `json:"prompt_tokens"`
	CompletionTokens   int64 `json:"completion_tokens"`
}

func (a *ProviderInsightAmounts) Add(b ProviderInsightAmounts) {
	a.WorkMicroUSD += b.WorkMicroUSD
	a.BaseRewardMicroUSD += b.BaseRewardMicroUSD
	a.Jobs += b.Jobs
	a.PromptTokens += b.PromptTokens
	a.CompletionTokens += b.CompletionTokens
}

type ProviderInsightGroup struct {
	Day        string `json:"day"`
	Model      string `json:"model"`
	ProviderID string `json:"provider_id"`
	ProviderInsightAmounts
}

const providerInsightGroupLimit = 10000

func validateInsightWindow(since, until time.Time) error {
	if !until.After(since) || until.Sub(since) > 31*24*time.Hour {
		return fmt.Errorf("provider insights: window must be positive and at most 31 days")
	}
	return nil
}

func (s *MemoryStore) ProviderInsightGroups(ctx context.Context, account string, since, until time.Time) ([]ProviderInsightGroup, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := validateInsightWindow(since, until); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	type key struct{ day, model, provider string }
	groups := make(map[key]ProviderInsightAmounts)
	for _, e := range s.providerEarnings {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if e.AccountID != account || e.CreatedAt.Before(since) || !e.CreatedAt.Before(until) {
			continue
		}
		k := key{e.CreatedAt.UTC().Format(time.DateOnly), e.Model, e.ProviderID}
		a := groups[k]
		if e.Model == "base_reward" {
			a.BaseRewardMicroUSD += e.AmountMicroUSD
		} else {
			a.WorkMicroUSD += e.AmountMicroUSD
			a.Jobs++
			a.PromptTokens += int64(e.PromptTokens)
			a.CompletionTokens += int64(e.CompletionTokens)
		}
		groups[k] = a
		if len(groups) > providerInsightGroupLimit {
			return nil, fmt.Errorf("provider insights: too many groups")
		}
	}
	out := make([]ProviderInsightGroup, 0, len(groups))
	for k, a := range groups {
		out = append(out, ProviderInsightGroup{Day: k.day, Model: k.model, ProviderID: k.provider, ProviderInsightAmounts: a})
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Day != b.Day {
			return a.Day < b.Day
		}
		if a.Model != b.Model {
			return a.Model < b.Model
		}
		return a.ProviderID < b.ProviderID
	})
	return out, nil
}
