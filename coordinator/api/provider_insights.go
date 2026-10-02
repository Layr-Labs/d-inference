package api

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type providerInsightSlice struct {
	ID string `json:"id"`
	store.ProviderInsightAmounts
}

type providerInsightsResponse struct {
	Window   string                        `json:"window"`
	Since    time.Time                     `json:"since"`
	AsOf     time.Time                     `json:"as_of"`
	Lifetime store.ProviderEarningsSummary `json:"lifetime"`
	Totals   store.ProviderInsightAmounts  `json:"totals"`
	Days     []providerInsightSlice        `json:"days"`
	Models   []providerInsightSlice        `json:"models"`
	Machines []providerInsightSlice        `json:"machines"`
}

func insightSlices(values map[string]store.ProviderInsightAmounts) []providerInsightSlice {
	out := make([]providerInsightSlice, 0, len(values))
	for id, a := range values {
		out = append(out, providerInsightSlice{ID: id, ProviderInsightAmounts: a})
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

func buildProviderInsights(window string, since, now time.Time, lifetime store.ProviderEarningsSummary, groups []store.ProviderInsightGroup) providerInsightsResponse {
	out := providerInsightsResponse{Window: window, Since: since, AsOf: now, Lifetime: lifetime, Days: []providerInsightSlice{}}
	days, models, machines := map[string]store.ProviderInsightAmounts{}, map[string]store.ProviderInsightAmounts{}, map[string]store.ProviderInsightAmounts{}
	for _, g := range groups {
		out.Totals.Add(g.ProviderInsightAmounts)
		for _, entry := range []struct {
			values map[string]store.ProviderInsightAmounts
			id     string
		}{{days, g.Day}, {models, g.Model}, {machines, g.ProviderID}} {
			a := entry.values[entry.id]
			a.Add(g.ProviderInsightAmounts)
			entry.values[entry.id] = a
		}
	}
	for day := since; day.Before(now); day = day.AddDate(0, 0, 1) {
		id := day.Format(time.DateOnly)
		out.Days = append(out.Days, providerInsightSlice{ID: id, ProviderInsightAmounts: days[id]})
	}
	out.Models, out.Machines = insightSlices(models), insightSlices(machines)
	return out
}

// Owner-only analytics. The window is calendar days in UTC, including today's
// partial day. This endpoint never accepts another account's ID from the caller.
func (s *Server) handleProviderInsights(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	user := s.requirePrivyUser(w, r)
	if user == nil {
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "window must be 7d or 30d"))
		return
	}
	cacheKey := "provider-insights:" + user.AccountID + ":" + window
	if body, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, body)
		return
	}
	reader, ok := store.As[store.ProviderInsightsReader](s.store)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "Provider insights unavailable"))
		return
	}
	now := time.Now().UTC()
	since := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC).AddDate(0, 0, -(days - 1))
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	groups, err := reader.ProviderInsightGroups(ctx, user.AccountID, since, now)
	if err != nil {
		s.logger.Error("provider insights aggregate failed", "error", err)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "Could not load provider insights"))
		return
	}
	lifetime, err := s.store.GetAccountEarningsSummary(user.AccountID)
	if err != nil {
		s.logger.Error("provider insights lifetime read failed", "error", err)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "Could not load lifetime totals"))
		return
	}
	body, err := json.Marshal(buildProviderInsights(window, since, now, lifetime, groups))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "Could not encode insights"))
		return
	}
	s.readCache.Set(cacheKey, body, 30*time.Second)
	writeCachedJSON(w, body)
}
