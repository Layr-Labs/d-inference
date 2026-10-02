package api

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Decimal strings preserve ledger and counter precision across the native/JS boundary.
type desktopInsightAmounts struct {
	WorkMicroUSD       int64 `json:"work_micro_usd,string"`
	BaseRewardMicroUSD int64 `json:"base_reward_micro_usd,string"`
	Jobs               int64 `json:"jobs,string"`
	PromptTokens       int64 `json:"prompt_tokens,string"`
	CompletionTokens   int64 `json:"completion_tokens,string"`
}

func desktopAmounts(a store.ProviderInsightAmounts) desktopInsightAmounts {
	return desktopInsightAmounts{a.WorkMicroUSD, a.BaseRewardMicroUSD, a.Jobs, a.PromptTokens, a.CompletionTokens}
}

type desktopLifetime struct {
	Count            int64 `json:"count,string"`
	TotalMicroUSD    int64 `json:"total_micro_usd,string"`
	PromptTokens     int64 `json:"prompt_tokens,string"`
	CompletionTokens int64 `json:"completion_tokens,string"`
}
type desktopInsightSlice struct {
	ID string `json:"id"`
	desktopInsightAmounts
}
type desktopInsights struct {
	AccountID string                `json:"account_id"`
	Window    string                `json:"window"`
	Since     time.Time             `json:"since"`
	AsOf      time.Time             `json:"as_of"`
	Lifetime  desktopLifetime       `json:"lifetime"`
	Totals    desktopInsightAmounts `json:"totals"`
	Days      []desktopInsightSlice `json:"days"`
	Models    []desktopInsightSlice `json:"models"`
	Machines  []desktopInsightSlice `json:"machines"`
}

func desktopInsightSlices(values map[string]store.ProviderInsightAmounts) []desktopInsightSlice {
	out := make([]desktopInsightSlice, 0, len(values))
	for id, a := range values {
		out = append(out, desktopInsightSlice{ID: id, desktopInsightAmounts: desktopAmounts(a)})
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		x, y := a.WorkMicroUSD+a.BaseRewardMicroUSD, b.WorkMicroUSD+b.BaseRewardMicroUSD
		if x != y {
			return x > y
		}
		return a.ID < b.ID
	})
	return out
}
func buildDesktopInsights(account, window string, since, now time.Time, lifetime store.ProviderEarningsSummary, groups []store.ProviderInsightGroup) desktopInsights {
	out := desktopInsights{AccountID: account, Window: window, Since: since, AsOf: now, Lifetime: desktopLifetime{lifetime.Count, lifetime.TotalMicroUSD, lifetime.PromptTokens, lifetime.CompletionTokens}, Days: []desktopInsightSlice{}}
	days, models, machines := map[string]store.ProviderInsightAmounts{}, map[string]store.ProviderInsightAmounts{}, map[string]store.ProviderInsightAmounts{}
	var total store.ProviderInsightAmounts
	for _, g := range groups {
		total.Add(g.ProviderInsightAmounts)
		for _, e := range []struct {
			m  map[string]store.ProviderInsightAmounts
			id string
		}{{days, g.Day}, {models, g.Model}, {machines, g.ProviderID}} {
			a := e.m[e.id]
			a.Add(g.ProviderInsightAmounts)
			e.m[e.id] = a
		}
	}
	for day := since; day.Before(now); day = day.AddDate(0, 0, 1) {
		id := day.Format(time.DateOnly)
		out.Days = append(out.Days, desktopInsightSlice{ID: id, desktopInsightAmounts: desktopAmounts(days[id])})
	}
	out.Totals = desktopAmounts(total)
	out.Models = desktopInsightSlices(models)
	out.Machines = desktopInsightSlices(machines)
	return out
}
func (s *Server) handleDesktopInsights(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	account := consumerKeyFromContext(r.Context())
	if account == "" {
		writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "a linked provider token is required"))
		return
	}
	window := r.URL.Query().Get("window")
	if window == "" {
		window = "7d"
	}
	days := 7
	if window == "30d" {
		days = 30
	} else if window != "7d" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request", "window must be 7d or 30d"))
		return
	}
	key := "desktop-insights:" + account + ":" + window
	if body, ok := s.readCacheGet(key); ok {
		writeCachedJSON(w, body)
		return
	}
	reader, ok := store.As[store.ProviderInsightsReader](s.store)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "Earnings insights unavailable"))
		return
	}
	now := time.Now().UTC()
	since := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC).AddDate(0, 0, -(days - 1))
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	groups, err := reader.ProviderInsightGroups(ctx, account, since, now)
	if err != nil {
		s.logger.Error("desktop insights aggregate failed", "error", err)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "Earnings insights unavailable"))
		return
	}
	lifetime, err := s.store.GetAccountEarningsSummary(account)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "Lifetime earnings unavailable"))
		return
	}
	body, err := json.Marshal(buildDesktopInsights(account, window, since, now, lifetime, groups))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "Could not encode earnings"))
		return
	}
	s.readCacheSet(key, body, 30*time.Second)
	writeCachedJSON(w, body)
}
