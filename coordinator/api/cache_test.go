package api

import (
	"context"
	"testing"
	"time"
)

// PurgeExpired removes expired entries and keeps live ones.
func TestTTLCachePurgeExpired(t *testing.T) {
	c := newTTLCache()
	c.Set("stale", []byte("v"), -time.Second) // already expired
	c.Set("fresh", []byte("v"), time.Minute)  // live

	c.PurgeExpired()

	if c.Len() != 1 {
		t.Fatalf("PurgeExpired: got %d entries, want 1", c.Len())
	}
	if _, ok := c.Get("stale"); ok {
		t.Error("expired entry should be gone after PurgeExpired")
	}
	if _, ok := c.Get("fresh"); !ok {
		t.Error("live entry should survive PurgeExpired")
	}
}

func TestTTLCacheInvalidatePrefix(t *testing.T) {
	c := newTTLCache()
	c.Set("latest_release:v1:macos=26.0", []byte("a"), time.Minute)
	c.Set("latest_release:v1:macos=15.0", []byte("b"), time.Minute)
	c.Set("api_version:v1", []byte("c"), time.Minute)

	c.InvalidatePrefix("latest_release:v1:")

	if _, ok := c.Get("latest_release:v1:macos=26.0"); ok {
		t.Fatal("expected prefixed latest-release key to be invalidated")
	}
	if _, ok := c.Get("latest_release:v1:macos=15.0"); ok {
		t.Fatal("expected second prefixed latest-release key to be invalidated")
	}
	if _, ok := c.Get("api_version:v1"); !ok {
		t.Fatal("non-prefixed key should survive prefix invalidation")
	}
}

// The janitor actually reclaims expired entries (PurgeExpired was previously
// never scheduled, so high-cardinality keys lingered forever) and stops on ctx
// cancel.
func TestReadCacheJanitorPurgesExpiredAndStops(t *testing.T) {
	s := &Server{readCache: newTTLCache()}
	// An expired entry that nothing will ever re-read — only the janitor frees it.
	s.readCache.Set("stale", []byte("v"), -time.Second)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		s.runReadCacheJanitor(ctx, time.Millisecond)
		close(done)
	}()

	deadline := time.After(2 * time.Second)
	for s.readCache.Len() != 0 {
		select {
		case <-deadline:
			t.Fatal("janitor did not purge the expired entry")
		default:
			time.Sleep(time.Millisecond)
		}
	}

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("janitor did not stop on context cancel")
	}
}
