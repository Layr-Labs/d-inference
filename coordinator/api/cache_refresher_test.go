package api

import (
	"bytes"
	"context"
	"testing"
	"time"
)

// A caller can observe a miss, then be descheduled until another caller has
// finished the fill. The flight lock alone does not coalesce that sequence.
func TestCachedEntryRechecksAfterDelayedMiss(t *testing.T) {
	srv, _, _ := newStatsRefresherFixture(t)
	const key = "test:delayed-miss"
	var entry cacheRefresher
	if _, ok := srv.readCache.Get(key); ok {
		t.Fatal("expected cold cache")
	}
	calls := 0
	compute := func() ([]byte, error) { calls++; return []byte(`{"value":1}`), nil }
	first, ok := srv.getCachedEntry(&entry, key, compute)
	if !ok {
		t.Fatal("first fill failed")
	}
	delayed, ok := srv.getCachedEntry(&entry, key, compute)
	if !ok || !bytes.Equal(delayed, first) || calls != 1 {
		t.Fatalf("delayed miss: ok=%v calls=%d", ok, calls)
	}
	// The periodic owner still refreshes an unexpired entry.
	if _, ok := srv.refreshCachedEntry(&entry, key, compute); !ok || calls != 2 {
		t.Fatalf("periodic refresh: ok=%v calls=%d", ok, calls)
	}
}

func TestCacheRefreshLoopCancelledBeforeStart(t *testing.T) {
	srv, _, _ := newStatsRefresherFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	srv.runCacheRefreshLoop(ctx, time.Minute, func() { t.Fatal("queried after shutdown") })
}
