package cachepersist_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestDemandGranularityFollowsShortTTLAndRestoreIsCapped(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	// A 30 s TTL bounds the granularity to 7.5 s; the default minute would
	// leave the durable timestamp older than the TTL while the key is still
	// hot in memory, so it would not survive a restart.
	p := New(mem, nil, Options{MaxPending: 10, DemandTTL: 30 * time.Second})
	if p.DemandGranularity != 7500*time.Millisecond {
		t.Fatalf("granularity not bounded by the TTL: %v", p.DemandGranularity)
	}
	restoreForTest(t, p, now)
	p.MarkDemand([]string{"k"}, now)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.MarkDemand([]string{"k"}, now.Add(5*time.Second))
	if b := pendingBatch(p); len(b.Demand) != 0 {
		t.Fatalf("refresh inside the granularity must be skipped: %+v", b.Demand)
	}
	p.MarkDemand([]string{"k"}, now.Add(20*time.Second))
	if b := pendingBatch(p); len(b.Demand) != 1 || !b.Demand[0].SeenAt.Equal(now.Add(20*time.Second)) {
		t.Fatalf("refresh past the granularity must persist: %+v", b.Demand)
	}
	// A long TTL keeps the default minute.
	if q := New(mem, nil, Options{MaxPending: 10, DemandTTL: 29 * time.Minute}); q.DemandGranularity != DemandPersistGranularity {
		t.Fatalf("long TTL must keep the default granularity: %v", q.DemandGranularity)
	}
	// A capped restore keeps the newest demand keys and stays within the TTL.
	mem = memory.NewMemory(store.Config{})
	var rows []crs.DemandRecord
	for i := 0; i < 5; i++ {
		rows = append(rows, crs.DemandRecord{Key: string(rune('a' + i)), SeenAt: now.Add(time.Duration(i) * time.Second)})
	}
	rows = append(rows, crs.DemandRecord{Key: "expired", SeenAt: now.Add(-2 * time.Minute)})
	if err := mem.UpsertCacheDemand(ctx, rows); err != nil {
		t.Fatal(err)
	}
	demand, err := New(mem, nil, Options{MaxPending: 10}).Restore(ctx, now.Add(10*time.Second), time.Minute, 10, 2)
	if err != nil || len(demand) != 2 || demand[0].Key != "e" || demand[1].Key != "d" {
		t.Fatalf("capped demand restore must keep the newest keys: %+v %v", demand, err)
	}
	demand, err = New(mem, nil, Options{MaxPending: 10}).Restore(ctx, now.Add(10*time.Second), time.Minute, 10, 0)
	if err != nil || len(demand) != 5 {
		t.Fatalf("uncapped restore must drop only the expired key: %+v %v", demand, err)
	}
}

// Demand rows stamped after now by a previous instance's fast clock are not
// restored, and only the entries the registry's index accepted are treated as
// already persisted.
func TestRestoreBoundsDemandToNowAndSeedsOnlyAcceptedKeys(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	if err := mem.UpsertCacheDemand(ctx, []crs.DemandRecord{
		{Key: "future", SeenAt: now.Add(time.Hour)},
		{Key: "fresh", SeenAt: now.Add(-time.Second)},
		{Key: "edge", SeenAt: now.Add(-time.Minute)},
	}); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, Options{MaxPending: 10, DemandTTL: time.Minute})
	demand, err := p.Restore(ctx, now, time.Minute, 10, 1)
	if err != nil || len(demand) != 1 || demand[0].Key != "fresh" {
		t.Fatalf("the future row must not take the cap: %+v %v", demand, err)
	}
	if s := p.Status(); s.RestoredDemand != 0 {
		t.Fatalf("nothing counts as restored before the index accepts it: %+v", s)
	}
	// The registry accepted "fresh" only; "edge" (rejected by the index) is
	// not seeded, so its next observation is written.
	p.SeedDemandPersisted([]crs.DemandRecord{{Key: "fresh", SeenAt: now.Add(-time.Second)}})
	if s := p.Status(); s.RestoredDemand != 1 {
		t.Fatalf("restored demand counts accepted entries: %+v", s)
	}
	p.MarkDemand([]string{"fresh", "edge", "future"}, now)
	b := pendingBatch(p)
	keys := map[string]bool{}
	for _, d := range b.Demand {
		keys[d.Key] = true
	}
	if keys["fresh"] || !keys["edge"] || !keys["future"] {
		t.Fatalf("seeded key suppressed, others written: %+v", b.Demand)
	}
}

// A backlog overflow while the rows are loading releases decisions that
// condemn rows no per-row check can see: the restore resets instead of
// parking them.
func TestRestoreResetsWhenTheBacklogOverflowsDuringTheLoad(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	condemned := rec("condemned", "e", now, time.Minute)
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{condemned}); err != nil {
		t.Fatal(err)
	}
	st := &loadHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	st.onLoadHolders = func() {
		// The row's decision is released by the overflow the fillers cause.
		p.MarkHolderDelete(condemned.HolderKey(), now.Add(time.Second))
		for i := 0; i < p.DirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	restoreForTest(t, p, now)
	if s := p.Status(); s.RestoredHolders != 0 || s.PendingHolders != 0 || s.OverflowResets != 1 || !s.Ready || st.resets != 1 {
		t.Fatalf("an overflow during the load must turn the restore into a reset: %+v resets=%d", s, st.resets)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 {
		t.Fatalf("the reset must remove the condemned row: %+v", rows)
	}
}

// An overflow during a load that returns nothing still turns the restore
// into a reset: only the check after the merge loop sees it, and the copy
// must not count as established with released decisions outstanding.
func TestRestoreResetsWhenTheBacklogOverflowsDuringAnEmptyLoad(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	now := time.Now()
	st := &loadHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	st.onLoadHolders = func() {
		for i := 0; i <= p.DirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	restoreForTest(t, p, now)
	p.Mu.Lock()
	pending := p.ResetPending
	p.Mu.Unlock()
	if s := p.Status(); !s.Ready || s.OverflowResets != 1 || st.resets != 1 || pending {
		t.Fatalf("an overflow during an empty load must reset before the copy counts as established: %+v resets=%d pending=%v", s, st.resets, pending)
	}
}

// loadHookStore runs a hook inside the holder load (the window between a
// restore's first overflow check and its merge) and counts resets.
type loadHookStore struct {
	crs.Store
	onLoadHolders func()
	resets        int
}

func (s *loadHookStore) LoadCacheHolders(ctx context.Context, now time.Time, ttl time.Duration, limit int) ([]crs.HolderRecord, error) {
	if hook := s.onLoadHolders; hook != nil {
		s.onLoadHolders = nil
		hook()
	}
	return s.Store.LoadCacheHolders(ctx, now, ttl, limit)
}

func (s *loadHookStore) ResetCacheRoutingState(ctx context.Context, fingerprint string) error {
	s.resets++
	return s.Store.ResetCacheRoutingState(ctx, fingerprint)
}
