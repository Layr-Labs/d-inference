package reporting_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	ranking "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/ranking"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func getLeaderboardForTest(t *testing.T, server *httptest.Server, query string, wantStatus int) (map[string]any, http.Header) {
	t.Helper()
	res, err := server.Client().Get(server.URL + "/v1/leaderboard?" + query)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != wantStatus {
		t.Fatalf("status=%d want=%d body=%v", res.StatusCode, wantStatus, body)
	}
	return body, res.Header
}

// A real query error yields a retryable 503 and a bounded failure cooldown;
// restoring the table and expiring that cooldown permits recovery.
func TestLeaderboardStoreErrorIs503NotEmptyBoard(t *testing.T) {
	srv, counter, control := newLeaderboardPostgresFixture(t)
	httpServer := httptest.NewServer(http.HandlerFunc(srv.HandleLeaderboard))
	defer httpServer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := control.Exec(ctx, "ALTER TABLE provider_earnings RENAME TO earnings_unavailable"); err != nil {
		t.Fatal(err)
	}
	body, headers := getLeaderboardForTest(t, httpServer, "metric=earnings&window=24h", http.StatusServiceUnavailable)
	errObj, _ := body["error"].(map[string]any)
	if errObj["code"] != "service_unavailable" {
		t.Fatalf("error envelope = %v", errObj)
	}
	seconds, err := strconv.Atoi(headers.Get("Retry-After"))
	if err != nil || seconds < 1 || seconds > int(ranking.FailureBackoff/time.Second) {
		t.Fatalf("Retry-After = %q", headers.Get("Retry-After"))
	}
	key := ranking.CacheKey(store.LeaderboardEarnings, "24h")
	if _, err, ok := srv.Cached(key); !ok || err == nil {
		t.Fatal("failure must retain a cooldown, not a successful ranking")
	}
	if _, err := control.Exec(ctx, "ALTER TABLE earnings_unavailable RENAME TO provider_earnings"); err != nil {
		t.Fatal(err)
	}
	// Changed limits and aliases cannot bypass the failed fill's cooldown.
	getLeaderboardForTest(t, httpServer, "metric=earnings&window=1d&limit=200", http.StatusServiceUnavailable)
	if got := counter.calls.Load(); got != 1 {
		t.Fatalf("queries during cooldown=%d, want 1", got)
	}
	value, _ := srv.readCache.GetValue(key)
	srv.readCache.SetValue(key, value, -time.Second)
	body, _ = getLeaderboardForTest(t, httpServer, "metric=earnings&window=24h", http.StatusOK)
	entries, _ := body["entries"].([]any)
	if len(entries) != 1 {
		t.Fatalf("entries=%v, want one recovered provider", entries)
	}
	if _, err, ok := srv.Cached(key); !ok || err != nil {
		t.Fatal("successful ranking was not cached")
	}
	if got := counter.calls.Load(); got != 2 {
		t.Fatalf("queries after recovery=%d, want 2", got)
	}
}

func TestLeaderboardEmptyWindowIs200(t *testing.T) {
	srv := newStatsSnapshotServer(memory.NewMemory(store.Config{}))
	httpServer := httptest.NewServer(http.HandlerFunc(srv.HandleLeaderboard))
	defer httpServer.Close()
	body, _ := getLeaderboardForTest(t, httpServer, "window=7d", http.StatusOK)
	entries, ok := body["entries"].([]any)
	if !ok || len(entries) != 0 {
		t.Fatalf("entries = %v, want empty array", body["entries"])
	}
	if _, err, ok := srv.Cached(ranking.CacheKey(store.LeaderboardEarnings, "7d")); !ok || err != nil {
		t.Fatal("successful empty leaderboard was not cached")
	}
}
