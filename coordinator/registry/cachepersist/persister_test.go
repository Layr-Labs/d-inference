package cachepersist

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// flakyStore fails every write while broken is set.
type flakyStore struct {
	crs.Store
	broken bool
}

func (f *flakyStore) UpsertCacheHolders(ctx context.Context, r []crs.HolderRecord) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.Store.UpsertCacheHolders(ctx, r)
}

func (f *flakyStore) UpsertCacheDemand(ctx context.Context, r []crs.DemandRecord) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.Store.UpsertCacheDemand(ctx, r)
}

func rec(key, epoch string, now time.Time, ttl time.Duration) crs.HolderRecord {
	return crs.HolderRecord{Key: key, CacheEpoch: epoch, Tier: "ssd", ModelID: "model",
		AnchorChainHash: "h", AnchorTokenCount: 1024, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(ttl)}
}

func TestFlushRetriesUnwrittenRemainderAndDedupesDemand(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	flaky := &flakyStore{Store: mem, broken: true}
	p := New(flaky, nil, 1000)
	now := time.Now()
	p.MarkHolderUpsert(rec("key-1", "e", now, time.Minute))
	p.MarkDemand([]string{"d-1", "d-2"}, now)
	if err := p.Flush(context.Background()); err == nil {
		t.Fatal("flush must report the store failure")
	}
	if s := p.Status(); s.FlushErrors != 1 || s.RowsWritten != 0 || p.dirtyEmpty() {
		t.Fatalf("failure must keep the batch dirty: %+v", s)
	}
	flaky.broken = false
	if err := p.Flush(context.Background()); err != nil {
		t.Fatalf("retry flush: %v", err)
	}
	if rows, _ := mem.LoadCacheHolders(context.Background(), now, 0); len(rows) != 1 {
		t.Fatalf("requeued holder not written: %d", len(rows))
	}
	if d, _ := mem.LoadCacheDemand(context.Background(), now.Add(-time.Minute)); len(d) != 2 {
		t.Fatalf("requeued demand not written: %d", len(d))
	}
	// Within the granularity window the same key is not written again.
	p.MarkDemand([]string{"d-1"}, now.Add(10*time.Second))
	if b := p.drain(); len(b.demand) != 0 {
		t.Fatalf("demand key re-marked inside the granularity window: %+v", b.demand)
	}
	p.MarkDemand([]string{"d-1"}, now.Add(2*time.Minute))
	if b := p.drain(); len(b.demand) != 1 {
		t.Fatalf("demand key not re-marked after the window: %+v", b.demand)
	}
}

func TestFlushWritesInBoundedChunksAndKeepsPartialProgress(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, 100_000)
	now := time.Now()
	for i := 0; i < HolderFlushRows+300; i++ {
		p.MarkHolderUpsert(rec("k"+time.Duration(i).String(), "e", now, time.Minute))
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.RowsWritten != HolderFlushRows || p.dirtyEmpty() {
		t.Fatalf("one flush must write at most %d holders and carry the rest: %+v", HolderFlushRows, s)
	}
	if err := p.FlushAll(context.Background()); err != nil || !p.dirtyEmpty() {
		t.Fatalf("FlushAll must drain the remainder: %v", err)
	}
	if rows, _ := mem.LoadCacheHolders(context.Background(), now, 0); len(rows) != HolderFlushRows+300 {
		t.Fatalf("rows written: %d", len(rows))
	}
}

func TestPendingParkTakeDropAndPrune(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, 2)
	now := time.Now()
	p.Park(rec("a", "e1", now, time.Minute))
	p.Park(rec("b", "e1", now, -time.Second)) // already expired
	p.Park(rec("c", "e1", now, time.Minute))  // over the cap of 2
	if s := p.Status(); s.PendingHolders != 2 || s.DroppedPending != 1 || !p.HasPending() {
		t.Fatalf("park accounting: %+v", s)
	}
	if rows := p.Take("e1", "other-model"); rows != nil {
		t.Fatalf("another model must not take the rows: %+v", rows)
	}
	p.prunePending(now)
	if s := p.Status(); s.PendingHolders != 1 || s.DroppedPending != 2 {
		t.Fatalf("prune must drop the expired row: %+v", s)
	}
	rows := p.Take("e1", "model")
	if len(rows) != 1 || rows[0].Key != "a" || p.HasPending() {
		t.Fatalf("take: %+v", rows)
	}
	p.AddBound(1, 0)
	p.Park(rec("d", "e2", now, time.Minute))
	p.Drop("e2", "model")
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.BoundHolders != 1 || s.PendingHolders != 0 || s.RowsDeleted != 1 {
		t.Fatalf("drop must delete the durable row: %+v", s)
	}
}

func TestRestoreClampsToCurrentTTLAndKeepsLongestLived(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	now := time.Now()
	ctx := context.Background()
	// Written under a 60-minute TTL 20 minutes ago; today's TTL is 29 minutes.
	old := rec("old", "e", now.Add(-20*time.Minute), 60*time.Minute)
	stale := rec("stale", "e", now.Add(-40*time.Minute), 60*time.Minute) // past UpdatedAt+29m
	fresh := rec("fresh", "e", now, 29*time.Minute)
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{old, stale, fresh}); err != nil {
		t.Fatal(err)
	}
	if err := mem.UpsertCacheDemand(ctx, []crs.DemandRecord{{Key: "d", SeenAt: now}}); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, 1000)
	demand, err := p.Restore(ctx, now, 29*time.Minute, 1000)
	if err != nil || len(demand) != 1 {
		t.Fatalf("restore: %v %+v", err, demand)
	}
	if s := p.Status(); s.RestoredHolders != 2 || s.DroppedPending != 1 {
		t.Fatalf("stale row must be dropped, old row clamped: %+v", s)
	}
	rows := p.Take("e", "model")
	for _, r := range rows {
		if r.Key == "old" && !r.ExpiresAt.Equal(r.UpdatedAt.Add(29*time.Minute)) {
			t.Fatalf("old row not clamped to the current TTL: %+v", r)
		}
	}
	// A capped restore keeps the longest-lived rows.
	p2 := New(mem, nil, 1000)
	if _, err := p2.Restore(ctx, now, 29*time.Minute, 1); err != nil {
		t.Fatal(err)
	}
	if rows := p2.Take("e", "model"); len(rows) != 1 || rows[0].Key != "old" {
		t.Fatalf("capped restore must keep the longest-lived row (old expires latest before clamping): %+v", rows)
	}
}
