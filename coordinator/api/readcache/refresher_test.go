package readcache

import (
	"bytes"
	"testing"
	"time"
)

// A caller can observe a miss, then be descheduled until another caller has
// finished the fill. The flight lock alone does not coalesce that sequence.
func TestCachedEntryRechecksAfterDelayedMiss(t *testing.T) {
	cache := New()
	const key = "test:delayed-miss"
	var entry Refresher
	if _, ok := cache.Get(key); ok {
		t.Fatal("expected cold cache")
	}
	calls := 0
	compute := func() ([]byte, error) { calls++; return []byte(`{"value":1}`), nil }
	first, ok := entry.Get(cache, key, 5*time.Minute, compute)
	if !ok {
		t.Fatal("first fill failed")
	}
	delayed, ok := entry.Get(cache, key, 5*time.Minute, compute)
	if !ok || !bytes.Equal(delayed, first) || calls != 1 {
		t.Fatalf("delayed miss: ok=%v calls=%d", ok, calls)
	}
	// The periodic owner still refreshes an unexpired entry.
	if _, ok := entry.Refresh(cache, key, 5*time.Minute, compute); !ok || calls != 2 {
		t.Fatalf("periodic refresh: ok=%v calls=%d", ok, calls)
	}
}
