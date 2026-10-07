package cachepersist_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestPendingParkTakeAndPrune(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 2})
	now := time.Now()
	restoreForTest(t, p, now)
	p.Park(rec("a", "e1", now, time.Minute))
	p.Park(rec("b", "e1", now, -time.Second)) // already expired
	p.Park(rec("c", "e1", now, time.Minute))  // over the cap of 2
	if s := p.Status(); s.PendingHolders != 2 || s.DroppedPending != 1 || !p.HasPending() {
		t.Fatalf("park accounting: %+v", s)
	}
	if rows, _ := p.Take("e1", "other-model", 0); rows != nil {
		t.Fatalf("another model must not take the rows: %+v", rows)
	}
	p.prunePending(now)
	if s := p.Status(); s.PendingHolders != 1 || s.DroppedPending != 2 {
		t.Fatalf("prune must drop the expired row: %+v", s)
	}
	rows, _ := p.Take("e1", "model", 0)
	if len(rows) != 1 || rows[0].Key != "a" || p.HasPending() {
		t.Fatalf("take: %+v", rows)
	}
	p.AddBound(1, 0)
	// A capability that is gone: the registry takes the rows, settles each
	// durable row (here: delete) and reports them dropped.
	p.Park(rec("d", "e2", now, time.Minute))
	taken, _ := p.Take("e2", "model", 0)
	for _, r := range taken {
		p.MarkHolderDelete(r.HolderKey(), time.Now())
		p.AddBound(0, 1)
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.BoundHolders != 1 || s.PendingHolders != 0 || s.DroppedPending != 3 || s.RowsDeleted != 1 {
		t.Fatalf("dropped rows must be deleted and counted: %+v", s)
	}
}

// A prune pops only the expired parked rows off the expiry order, in
// bounded chunks; rows taken or merged meanwhile have left or moved their
// entry already.
func TestPrunePendingPopsOnlyExpiredRowsInChunks(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 100_000})
	now := time.Now()
	const expired, live = 2*pruneBatchRows + 7, 100
	for i := 0; i < expired; i++ {
		p.Park(rec(fmt.Sprintf("x%05d", i), "e", now.Add(-2*time.Minute), time.Minute)) // expired
	}
	for i := 0; i < live; i++ {
		p.Park(rec(fmt.Sprintf("l%05d", i), "e", now, time.Minute))
	}
	// Extending a live row's expiry by a merge moves its entry in the expiry
	// order rather than adding a second one.
	extended := rec("l00000", "e", now, 2*time.Minute)
	p.Park(extended)
	checkParkedExpiryIndex(t, p)
	// A parked row taken before the prune takes its entry with it.
	taken, _ := p.Take("e", "model", 1)
	if len(taken) != 1 {
		t.Fatal("take one row")
	}
	checkParkedExpiryIndex(t, p)
	// One lock hold drops at most its chunk and reports the rest.
	p.Mu.Lock()
	more := p.PrunePendingBatch(now, 5)
	dropped := p.Counters.DroppedPending
	p.Mu.Unlock()
	if !more || dropped != 5 {
		t.Fatalf("a bounded chunk must drop exactly its chunk and report more: more=%v dropped=%d", more, dropped)
	}
	checkParkedExpiryIndex(t, p)
	p.Prune(context.Background(), now, time.Minute) // not ready: parked prune only
	checkParkedExpiryIndex(t, p)
	s := p.Status()
	wantLive := live
	if taken[0].Key[0] == 'l' {
		wantLive--
	}
	if s.PendingHolders != wantLive || s.DroppedPending != uint64(expired)-uint64(map[bool]int{true: 1, false: 0}[taken[0].Key[0] == 'x']) {
		t.Fatalf("prune must drop exactly the expired rows: %+v (taken %s)", s, taken[0].Key)
	}
	rows, _ := p.Take("e", "model", 0)
	for _, r := range rows {
		if r.Key[0] != 'l' {
			t.Fatalf("expired row survived the prune: %+v", r)
		}
		if r.Key == "l00000" && !r.ExpiresAt.Equal(now.Add(2*time.Minute)) {
			t.Fatalf("the merged expiry must stand: %+v", r)
		}
	}
	if p.HasPending() {
		t.Fatal("everything live was taken")
	}
}
