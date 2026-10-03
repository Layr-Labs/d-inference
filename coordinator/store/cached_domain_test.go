package store

import (
	"testing"
	"time"
)

func TestDomainCacheBoundedEviction(t *testing.T) {
	clock := newFakeClock()
	c := newDomainCache[User](time.Minute, time.Second, 2, clock.now)
	load := func(id string) func() (*User, error) {
		return func() (*User, error) { return &User{AccountID: id}, nil }
	}
	ident := func(u *User) *User { return u }

	c.get("a", load("a"), ident)
	c.get("b", load("b"), ident)
	c.get("c", load("c"), ident) // over capacity: one live entry is evicted
	if n := c.size(); n != 2 {
		t.Fatalf("size after 3 inserts with cap 2 = %d, want 2", n)
	}
	if ev := c.counters().Evictions; ev != 1 {
		t.Fatalf("evictions = %d, want 1", ev)
	}
	// Re-inserting an existing key never evicts.
	c.invalidate()
	c.get("a", load("a"), ident)
	c.get("b", load("b"), ident)
	c.get("a", load("a"), ident)
	if ev := c.counters().Evictions; ev != 1 {
		t.Fatalf("hit on an existing key evicted: evictions = %d", ev)
	}

	// Expired entries are reclaimed before any live one is dropped.
	c.invalidate()
	c.get("a", load("a"), ident)
	c.get("b", load("b"), ident)
	clock.advance(2 * time.Minute)
	c.get("c", load("c"), ident)
	if n := c.size(); n != 1 {
		t.Fatalf("size after expiry sweep = %d, want 1 (only the new entry)", n)
	}
	if _, ok := c.lookup("c"); !ok {
		t.Fatal("new entry missing after sweep")
	}
}

func TestDomainCacheZeroTTLNeverStores(t *testing.T) {
	c := newDomainCache[User](0, 0, 10, nil)
	loads := 0
	load := func() (*User, error) { loads++; return &User{AccountID: "a"}, nil }
	ident := func(u *User) *User { return u }
	c.get("a", load, ident)
	c.get("a", load, ident)
	if loads != 2 || c.size() != 0 {
		t.Fatalf("zero TTL stored: loads=%d size=%d", loads, c.size())
	}
}
