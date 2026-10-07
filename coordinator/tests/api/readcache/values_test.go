package readcache_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/readcache"
)

// Typed values and bytes share the same map, without crossing entry kinds.
func TestTTLCacheTypedValues(t *testing.T) {
	c := production.New()
	c.SetValue("entries", []string{"a"}, time.Minute)
	c.Set("body", []byte("{}"), time.Minute)
	if v, ok := c.GetValue("entries"); !ok || len(v.([]string)) != 1 {
		t.Fatalf("GetValue = %v, %v", v, ok)
	}
	if _, ok := c.Get("entries"); ok {
		t.Fatal("typed entry returned as bytes")
	}
	if _, ok := c.GetValue("body"); ok {
		t.Fatal("byte entry returned as value")
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

func TestInvalidationFencesBothEntryKinds(t *testing.T) {
	c := production.New()
	generation := c.Generation()
	c.SetIfCurrent("body", []byte("old"), time.Minute, generation)
	c.SetValueIfCurrent("value", 1, time.Minute, generation)
	c.Invalidate("body")
	c.Invalidate("value")
	c.SetIfCurrent("body", []byte("stale fill"), time.Minute, generation)
	c.SetValueIfCurrent("value", 2, time.Minute, generation)
	if c.Len() != 0 {
		t.Fatal("stale fill resurrected invalidated entries")
	}
	generation = c.Generation()
	c.SetIfCurrent("body", []byte("new"), time.Minute, generation)
	c.SetValueIfCurrent("value", 3, time.Minute, generation)
	if b, ok := c.Get("body"); !ok || string(b) != "new" {
		t.Fatal("current byte fill lost")
	}
	if v, ok := c.GetValue("value"); !ok || v != 3 {
		t.Fatal("current value fill lost")
	}
}
