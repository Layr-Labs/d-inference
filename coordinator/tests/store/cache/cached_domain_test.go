package cache_test

import (
	. "github.com/eigeninference/d-inference/coordinator/store"

	"testing"
	"time"

	storecache "github.com/eigeninference/d-inference/coordinator/internal/store/storecache"
)

func TestDomainCacheBoundedEviction(t *testing.T) {
	clock := newFakeClock()
	c := storecache.New[User](time.Minute, time.Second, 2, clock.now, ErrNotFound)
	load := func(id string) func() (*User, error) {
		return func() (*User, error) { return &User{AccountID: id}, nil }
	}
	ident := func(u *User) *User { return u }

	c.Get("a", load("a"), ident)
	c.Get("b", load("b"), ident)
	c.Get("c", load("c"), ident) // over capacity: one live entry is evicted
	if n := c.Counters().Entries; n != 2 {
		t.Fatalf("size after 3 inserts with cap 2 = %d, want 2", n)
	}
	if ev := c.Counters().Evictions; ev != 1 {
		t.Fatalf("evictions = %d, want 1", ev)
	}
	// Re-inserting an existing key never evicts.
	c.Invalidate()
	c.Get("a", load("a"), ident)
	c.Get("b", load("b"), ident)
	c.Get("a", load("a"), ident)
	if ev := c.Counters().Evictions; ev != 1 {
		t.Fatalf("hit on an existing key evicted: evictions = %d", ev)
	}

	// Expired entries are reclaimed before any live one is dropped.
	c.Invalidate()
	c.Get("a", load("a"), ident)
	c.Get("b", load("b"), ident)
	clock.advance(2 * time.Minute)
	c.Get("c", load("c"), ident)
	if n := c.Counters().Entries; n != 1 {
		t.Fatalf("size after expiry sweep = %d, want 1 (only the new entry)", n)
	}
	if got, err := c.Get("c", func() (*User, error) { t.Fatal("new entry missing after sweep"); return nil, nil }, ident); err != nil || got.AccountID != "c" {
		t.Fatal("new entry missing after sweep")
	}
}

func TestDomainCacheZeroTTLNeverStores(t *testing.T) {
	c := storecache.New[User](0, 0, 10, nil, ErrNotFound)
	loads := 0
	load := func() (*User, error) { loads++; return &User{AccountID: "a"}, nil }
	ident := func(u *User) *User { return u }
	c.Get("a", load, ident)
	c.Get("a", load, ident)
	if loads != 2 || c.Counters().Entries != 0 {
		t.Fatalf("zero TTL stored: loads=%d size=%d", loads, c.Counters().Entries)
	}
}
