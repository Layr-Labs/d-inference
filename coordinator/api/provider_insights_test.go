package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestProviderInsightsOwnershipAndCache(t *testing.T) {
	srv, st := testServer(t)
	srv.store = store.NewCached(st, store.CacheConfig{})
	for _, entry := range []store.ProviderEarning{
		{AccountID: "owner", Model: "model", ProviderID: "mac", JobID: "one", AmountMicroUSD: 20, CompletionTokens: 100, CreatedAt: time.Now().Add(-time.Minute)},
		{AccountID: "other", Model: "model", ProviderID: "secret", JobID: "two", AmountMicroUSD: 700, CompletionTokens: 900, CreatedAt: time.Now().Add(-time.Minute)},
	} {
		if err := st.RecordProviderEarning(&entry); err != nil {
			t.Fatal(err)
		}
	}
	for _, account := range []string{"owner", "other", "owner"} {
		w := httptest.NewRecorder()
		srv.handleProviderInsights(w, reqWithUser(http.MethodGet, "/v1/me/provider-insights?window=7d&account_id=other", "", account))
		if w.Code != http.StatusOK {
			t.Fatalf("%d: %s", w.Code, w.Body.String())
		}
		if w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatal("account data may be cached publicly")
		}
		var result providerInsightsResponse
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		want := int64(20)
		if account == "other" {
			want = 700
		}
		if result.Totals.WorkMicroUSD != want || len(result.Days) != 7 || len(result.Machines) != 1 {
			t.Fatalf("account leak or bad bins: %+v", result)
		}
	}
}

func TestProviderInsightsRequiresOwnerAuthenticationAndFixedWindow(t *testing.T) {
	srv, _ := testServer(t)
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	response, err := server.Client().Get(server.URL + "/v1/me/provider-insights?account_id=owner")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusOK {
		t.Fatal("unauthenticated insights accessible")
	}
	for _, window := range []string{"all", "365d", "-1"} {
		w := httptest.NewRecorder()
		srv.handleProviderInsights(w, reqWithUser(http.MethodGet, "/v1/me/provider-insights?window="+window, "", "owner"))
		if w.Code != http.StatusBadRequest {
			t.Fatalf("invalid window %q: %d", window, w.Code)
		}
	}
}

func TestBuildProviderInsightsZeroDaysAndConsistentBreakdowns(t *testing.T) {
	start := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	result := buildProviderInsights("7d", start, start.Add(2*24*time.Hour+time.Hour), store.ProviderEarningsSummary{CompletionTokens: 1000}, []store.ProviderInsightGroup{
		{Day: "2026-10-01", Model: "model", ProviderID: "removed", ProviderInsightAmounts: store.ProviderInsightAmounts{WorkMicroUSD: 40, Jobs: 2, CompletionTokens: 100}},
		{Day: "2026-10-03", Model: "base_reward", ProviderInsightAmounts: store.ProviderInsightAmounts{BaseRewardMicroUSD: 300}},
	})
	if len(result.Days) != 3 || result.Days[1].Jobs != 0 || result.Totals.Jobs != 2 || result.Lifetime.CompletionTokens != 1000 {
		t.Fatalf("bad bins or totals: %+v", result)
	}
	for _, breakdown := range [][]providerInsightSlice{result.Days, result.Models, result.Machines} {
		var sum store.ProviderInsightAmounts
		for _, row := range breakdown {
			sum.Add(row.ProviderInsightAmounts)
		}
		if sum != result.Totals {
			t.Fatalf("breakdown %+v != %+v", sum, result.Totals)
		}
	}
}
