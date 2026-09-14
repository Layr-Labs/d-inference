package readcache

import (
	"testing"
	"time"
)

// PurgeExpired removes expired entries and keeps live ones.
func TestTTLCachePurgeExpired(t *testing.T) {
	c := New()
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

// Typed values share the map with byte entries: independent keys, TTL
// expiry, and Get/GetValue never return the other kind.
func TestTTLCacheTypedValues(t *testing.T) {
	c := New()
	c.SetValue("entries", []string{"a"}, time.Minute)
	c.Set("body", []byte("{}"), time.Minute)
	if v, ok := c.GetValue("entries"); !ok || len(v.([]string)) != 1 {
		t.Fatalf("GetValue = %v, %v", v, ok)
	}
	if _, ok := c.Get("entries"); ok {
		t.Fatal("Get must not return a typed entry as bytes")
	}
	if _, ok := c.GetValue("body"); ok {
		t.Fatal("GetValue must not return a byte entry as a value")
	}
	c.SetValue("stale", 1, -time.Second)
	if _, ok := c.GetValue("stale"); ok {
		t.Fatal("expired typed value returned")
	}
	c.PurgeExpired()
	if c.Len() != 2 {
		t.Fatalf("Len after purge = %d, want 2", c.Len())
	}
}
