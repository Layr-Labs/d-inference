package api

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// main.go wraps the backend in store.CachedStore, whose static Store method
// set hides the optional codeAttestPushBudgetStore capability from a direct
// type assertion. These tests run the durable reserve, clear and restart-seed
// paths over NewCached(NewMemory(...)) exactly as the bare-store tests do, and
// first prove the wrapped shape is what is under test.
func newCachedCodeAttestStore(t *testing.T) *store.CachedStore {
	t.Helper()
	cached := store.NewCached(store.NewMemory(store.Config{}), store.CacheConfig{})
	if _, direct := any(cached).(codeAttestPushBudgetStore); direct {
		t.Fatal("direct assertion on CachedStore succeeded; this test no longer exercises the wrapped path")
	}
	if _, ok := store.As[codeAttestPushBudgetStore](cached); !ok {
		t.Fatal("store.As cannot find codeAttestPushBudgetStore through CachedStore")
	}
	return cached
}

func TestCodeAttestDurableReservationThroughCachedStore(t *testing.T) {
	cached := newCachedCodeAttestStore(t)
	th := newCodeAttestThrottle()
	th.store = cached
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return now }

	generation := th.beginLoop("se-cached")
	if !th.tryReservePush(context.Background(), "se-cached", "token", false, generation) {
		t.Fatal("first push not admitted over the cached store")
	}
	budgets, _ := store.As[codeAttestPushBudgetStore](cached)
	rows, err := budgets.ListCodeAttestPushBudgets(context.Background())
	if err != nil || len(rows) != 2 { // token row + admission-floor sentinel
		t.Fatalf("durable reservation missing over cached store: rows=%+v err=%v", rows, err)
	}
	for _, row := range rows {
		if !row.NextPushAt.After(now) {
			t.Fatalf("non-future reservation window persisted: %+v", row)
		}
	}

	// The durable row, not just in-memory state, blocks a second instance.
	other := newCodeAttestThrottle()
	other.store = cached
	other.now = th.now
	if other.tryReservePush(context.Background(), "se-cached", "token", false, other.beginLoop("se-cached")) {
		t.Fatal("second instance re-spent a budget the durable store already holds")
	}
}

func TestCodeAttestDurableClearThroughCachedStore(t *testing.T) {
	cached := newCachedCodeAttestStore(t)
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	first := newCodeAttestThrottle()
	first.store = cached
	first.now = func() time.Time { return now }
	if !first.clearPushBudget(context.Background(), "se-clear") {
		t.Fatal("first rotation clear rejected over the cached store")
	}

	// A fresh instance (empty in-memory state) sharing the store must see
	// the durably spent clear window and refuse.
	second := newCodeAttestThrottle()
	second.store = cached
	second.now = first.now
	if second.clearPushBudget(context.Background(), "se-clear") {
		t.Fatal("durable clear cooldown not honored through the cached store")
	}
}

func TestCodeAttestSeedRestoresDurableBudgetsThroughCachedStore(t *testing.T) {
	cached := newCachedCodeAttestStore(t)
	now := time.Now().UTC()
	next := now.Add(time.Hour)
	tokenHash := codeAttestTokenHash("token-1")
	budgets, _ := store.As[codeAttestPushBudgetStore](cached)
	if ok, err := budgets.ReserveCodeAttestPushBudget(context.Background(), "se-seed", tokenHash, now, next); err != nil || !ok {
		t.Fatalf("pre-restart reservation: ok=%v err=%v", ok, err)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(registry.New(logger), cached, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.SeedCodeAttestCache(context.Background())

	th := srv.codeAttestThrottle
	th.mu.Lock()
	seeded, ok := th.durableNextPush[codeAttestPushBudgetKey("se-seed", tokenHash)]
	th.mu.Unlock()
	if !ok || !seeded.Equal(next) {
		t.Fatalf("restart seed over cached store: durableNextPush = %v (present=%v), want %v", seeded, ok, next)
	}
	if th.tryReservePush(context.Background(), "se-seed", "token-1", false, th.beginLoop("se-seed")) {
		t.Fatal("seeded durable budget did not block an immediate re-push")
	}
}
