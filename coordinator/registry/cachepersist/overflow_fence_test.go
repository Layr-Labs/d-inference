package cachepersist

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// A delayed receipt cannot resurrect evidence whose individual decision was
// released on overflow, including after a successful or failed reset.
func TestOverflowRejectsDelayedInvalidatedEvidence(t *testing.T) {
	for _, afterReset := range []bool{false, true} {
		t.Run(fmt.Sprintf("after_reset_%v", afterReset), func(t *testing.T) {
			ctx, now := context.Background(), time.Now()
			mem := memory.NewMemory(store.Config{})
			st := &resetCountingStore{Store: mem}
			opts := Options{MaxPending: 2, Fingerprint: "generation"}
			p := New(st, nil, opts)
			restoreForTest(t, p, now)
			old := rec("invalidated", "epoch", now, time.Minute)
			p.MarkHolderUpsert(old)
			if err := p.Flush(ctx); err != nil {
				t.Fatal(err)
			}
			p.MarkHolderDelete(old.HolderKey(), now.Add(time.Second))
			for i := 0; i < p.dirtyCap; i++ {
				p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("other-%d", i), CacheEpoch: "epoch"}, now.Add(time.Second))
			}
			if p.Status().OverflowResets != 1 {
				t.Fatal("test must release the invalidation through overflow")
			}
			st.failNext = 1
			if err := p.Flush(ctx); err == nil {
				t.Fatal("first reset must fail")
			}
			if afterReset {
				if err := p.FlushAll(ctx); err != nil {
					t.Fatal(err)
				}
			}
			p.MarkHolderUpsert(old)
			p.Park(old)
			if !p.Tombstoned(old.HolderKey(), old.UpdatedAt) || p.Status().StaleUpserts != 1 || p.HasPending() {
				t.Fatal("released invalidation must still fence delayed receipts and parked rows")
			}
			if err := p.FlushAll(ctx); err != nil {
				t.Fatal(err)
			}
			next := New(mem, nil, opts)
			if _, err := next.Restore(ctx, now.Add(2*time.Second), time.Minute, 2, 2); err != nil {
				t.Fatal(err)
			}
			if rows, _ := next.Take("epoch", "model", 2); len(rows) != 0 {
				t.Fatalf("restart resurrected invalidated evidence: %+v", rows)
			}
			// A receipt sampled after the decision proves the row afresh.
			fresh := rec(old.Key, old.CacheEpoch, now.Add(3*time.Second), time.Minute)
			p.MarkHolderUpsert(fresh)
			if err := p.FlushAll(ctx); err != nil {
				t.Fatal(err)
			}
			rows, err := mem.LoadCacheHolders(ctx, now.Add(4*time.Second), time.Minute, 0)
			if err != nil || len(rows) != 1 || !rows[0].UpdatedAt.Equal(fresh.UpdatedAt) {
				t.Fatalf("overflow cutoff rejected fresh evidence: %+v %v", rows, err)
			}
		})
	}
}
