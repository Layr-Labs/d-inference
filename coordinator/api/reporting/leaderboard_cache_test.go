package reporting

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestLeaderboardConcurrentAliasesAndLimitsShareQuery(t *testing.T) {
	srv, counter, control := newLeaderboardPostgresFixture(t)
	for i := 1; i < 8; i++ {
		if err := counter.RecordProviderEarning(&store.ProviderEarning{
			AccountID: fmt.Sprintf("acct-%d", i), Model: "m", JobID: fmt.Sprintf("job-%d", i),
			AmountMicroUSD: int64(i), PromptTokens: i, CreatedAt: time.Now(),
		}); err != nil {
			t.Fatal(err)
		}
	}
	const callers = 30
	arrived := make(chan struct{}, callers)
	handler := http.HandlerFunc(srv.HandleLeaderboard)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		arrived <- struct{}{}
		handler.ServeHTTP(w, r)
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, err := control.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	// Hold the actual SQL read so all HTTP callers contend for its fill.
	if _, err := tx.Exec(ctx, "LOCK TABLE provider_earnings IN ACCESS EXCLUSIVE MODE"); err != nil {
		t.Fatal(err)
	}
	var done sync.WaitGroup
	done.Add(callers)
	start := make(chan struct{})
	windows := []string{"", "all", "lifetime"}
	for i := range callers {
		go func() {
			defer done.Done()
			<-start
			limit := 1 + i%8
			window := windows[i%len(windows)]
			body, _ := getLeaderboardForTest(t, server, fmt.Sprintf("window=%s&limit=%d", window, limit), http.StatusOK)
			entries, _ := body["entries"].([]any)
			if len(entries) != limit || body["window"] != windowParamOrDefault(window) {
				t.Errorf("limit=%d window=%s: %v", limit, window, body)
			}
		}()
	}
	close(start)
	deadline := time.After(2 * time.Second)
	for range callers {
		select {
		case <-arrived:
		case <-deadline:
			t.Fatal("concurrent HTTP callers did not reach the handler")
		}
	}
	for counter.calls.Load() == 0 {
		select {
		case <-deadline:
			t.Fatal("ranking query never started")
		case <-time.After(time.Millisecond):
		}
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	done.Wait()
	if got := counter.calls.Load(); got != 1 {
		t.Fatalf("queries=%d, want one across aliases and limits", got)
	}
	if got := counter.limit.Load(); got != leaderboardCacheLimit {
		t.Fatalf("SQL limit=%d, want %d", got, leaderboardCacheLimit)
	}
	// The short-window aliases also share a fill; different metrics stay separate.
	getLeaderboardForTest(t, server, "window=24h&limit=1", http.StatusOK)
	getLeaderboardForTest(t, server, "window=1d&limit=200", http.StatusOK)
	if got := counter.calls.Load(); got != 2 {
		t.Fatalf("queries=%d after 24h aliases, want 2", got)
	}
	getLeaderboardForTest(t, server, "metric=tokens&window=24h", http.StatusOK)
	if got := counter.calls.Load(); got != 3 {
		t.Fatalf("queries=%d after tokens ranking, want 3", got)
	}
}

func TestLeaderboardFailureBurstSharesCooldown(t *testing.T) {
	srv, counter, control := newLeaderboardPostgresFixture(t)
	server := httptest.NewServer(http.HandlerFunc(srv.HandleLeaderboard))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := control.Exec(ctx, "ALTER TABLE provider_earnings RENAME TO earnings_unavailable"); err != nil {
		t.Fatal(err)
	}
	var done sync.WaitGroup
	const callers = 30
	done.Add(callers)
	for i := range callers {
		go func() {
			defer done.Done()
			window := []string{"", "all", "lifetime"}[i%3]
			getLeaderboardForTest(t, server, fmt.Sprintf("window=%s&limit=%d", window, i+1), http.StatusServiceUnavailable)
		}()
	}
	done.Wait()
	if got := counter.calls.Load(); got != 1 {
		t.Fatalf("failed queries=%d, want one", got)
	}
	// Sequential retries must also avoid restarting the failed SQL aggregate.
	getLeaderboardForTest(t, server, "window=all&limit=200", http.StatusServiceUnavailable)
	if got := counter.calls.Load(); got != 1 {
		t.Fatalf("queries after retry=%d, want one", got)
	}
}

func TestLeaderboardCancelledCallerDoesNotStartQuery(t *testing.T) {
	srv, counter, _ := newLeaderboardPostgresFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := srv.cachedLeaderboard(ctx, store.LeaderboardEarnings, "24h"); err != context.Canceled {
		t.Fatalf("error=%v, want context cancellation", err)
	}
	if counter.calls.Load() != 0 {
		t.Fatal("cancelled caller started a query")
	}
}
