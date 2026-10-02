package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/store"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDesktopInsightsOwnerOnlyExactAndRevocation(t *testing.T) {
	srv, st := testServer(t)
	srv.store = store.NewCached(st, store.DefaultCacheConfig())
	hash := sha256.Sum256([]byte("insights-test-token"))
	if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: hex.EncodeToString(hash[:]), AccountID: "owner", Active: true}); err != nil {
		t.Fatal(err)
	}
	for _, e := range []store.ProviderEarning{
		{AccountID: "owner", Model: "model", ProviderID: "removed", JobID: "one", AmountMicroUSD: 9007199254740993, PromptTokens: 20, CompletionTokens: 30, CreatedAt: time.Now().Add(-time.Minute)},
		{AccountID: "owner", Model: "base_reward", JobID: "reward", AmountMicroUSD: 500, CreatedAt: time.Now().Add(-time.Minute)},
		{AccountID: "other", Model: "secret-model", JobID: "secret", AmountMicroUSD: 700, CreatedAt: time.Now().Add(-time.Minute)},
	} {
		if err := st.RecordProviderEarning(&e); err != nil {
			t.Fatal(err)
		}
	}
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	read := func(window, token string) (int, string) {
		req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL+"/v1/provider/desktop/insights?account_id=other&window="+window, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, _ := io.ReadAll(res.Body)
		if res.StatusCode == 200 && res.Header.Get("Cache-Control") != "private, no-store" {
			t.Fatal("shared-cacheable account data")
		}
		return res.StatusCode, string(body)
	}
	if code, _ := read("7d", ""); code != 401 {
		t.Fatalf("unauthenticated %d", code)
	}
	for _, window := range []string{"7d", "30d", "7d"} {
		code, body := read(window, "insights-test-token")
		if code != 200 {
			t.Fatalf("%d: %s", code, body)
		}
		if strings.Contains(body, "secret") || strings.Contains(body, "other") {
			t.Fatal("cross-account data")
		}
		if !strings.Contains(body, `"work_micro_usd":"9007199254740993"`) {
			t.Fatal("lost integer precision", body)
		}
		var out desktopInsights
		if err := json.Unmarshal([]byte(body), &out); err != nil {
			t.Fatal(err)
		}
		count := 7
		if window == "30d" {
			count = 30
		}
		if len(out.Days) != count || out.Totals.Jobs != 1 || out.Totals.BaseRewardMicroUSD != 500 || out.Lifetime.CompletionTokens != 30 {
			t.Fatalf("bad totals: %+v", out)
		}
	}
	if code, _ := read("365d", "insights-test-token"); code != 400 {
		t.Fatal("unbounded window accepted")
	}
	if err := st.RevokeProviderToken("insights-test-token"); err != nil {
		t.Fatal(err)
	}
	if code, _ := read("7d", "insights-test-token"); code != 401 {
		t.Fatal("cached data survived token revocation")
	}
}
