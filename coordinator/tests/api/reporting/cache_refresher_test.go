package reporting_test

import (
	"bytes"
	"context"
	"testing"
	"time"

	refresher "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/refresher"
)

// A caller can observe a miss, then be descheduled until another caller has
// finished the fill. The flight lock alone does not coalesce that sequence.
func TestCachedEntryRechecksAfterDelayedMiss(t *testing.T) {
	srv, _, _ := newStatsRefresherFixture(t)
	const key = "test:delayed-miss"
	var entry refresher.Entry
	if _, ok := srv.readCache.Get(key); ok {
		t.Fatal("expected cold cache")
	}
	calls := 0
	compute := func() ([]byte, error) { calls++; return []byte(`{"value":1}`), nil }
	first, ok := srv.GetCachedEntry(&entry, key, compute)
	if !ok {
		t.Fatal("first fill failed")
	}
	delayed, ok := srv.GetCachedEntry(&entry, key, compute)
	if !ok || !bytes.Equal(delayed, first) || calls != 1 {
		t.Fatalf("delayed miss: ok=%v calls=%d", ok, calls)
	}
	// The periodic owner still refreshes an unexpired entry.
	if _, ok := srv.RefreshCachedEntry(&entry, key, compute); !ok || calls != 2 {
		t.Fatalf("periodic refresh: ok=%v calls=%d", ok, calls)
	}
}

func TestCacheRefreshLoopCancelledBeforeStart(t *testing.T) {
	srv, _, _ := newStatsRefresherFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	srv.RunCacheRefreshLoop(ctx, time.Minute, func() { t.Fatal("queried after shutdown") })
}
