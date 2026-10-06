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

// A written tombstone continues fencing older parked evidence until its
// decision is one TTL old; acknowledging the delete must not let stale
// evidence bind.
func TestTombstoneOutlivesItsFlushForOneTTL(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 10})
	restoreForTest(t, p, now)
	k := crs.HolderKey{Key: "a", CacheEpoch: "e"}
	before := now.Add(-time.Second)
	p.MarkHolderDelete(k, now)
	b, _ := p.Snapshot()
	if len(b.Deletes) != 1 || !p.Tombstoned(k, before) {
		t.Fatal("a snapshot must leave the pending deletion fence visible")
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !p.Tombstoned(k, before) {
		t.Fatal("acknowledgement must retain the deletion fence")
	}
	if p.Tombstoned(k, now.Add(time.Second)) || p.Tombstoned(crs.HolderKey{Key: "a", CacheEpoch: "other"}, before) {
		t.Fatal("only older evidence of the same identity is fenced")
	}
	p.Prune(context.Background(), now.Add(2*time.Minute), time.Minute)
	if p.Tombstoned(k, before) {
		t.Fatal("the retained fence must expire after one TTL")
	}
}

// A receipt sampled before an invalidation of the same durable row but
// applied after it must not cancel the tombstone or reach the store; a
// receipt newer than the decision supersedes the pending delete, but keeps
// its fence against older evidence.
func TestDelayedOlderReceiptCannotCancelANewerTombstone(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 10})
	restoreForTest(t, p, now)
	stale := rec("a", "e", now.Add(-time.Second), time.Minute)
	p.MarkHolderDelete(stale.HolderKey(), now)
	p.MarkHolderUpsert(stale)
	if b := pendingBatch(p); len(b.Deletes) != 1 || len(b.Upserts) != 0 {
		t.Fatalf("stale receipt must leave the delete pending: %+v", b)
	}
	fresh := rec("a", "e", now.Add(time.Second), time.Minute)
	p.MarkHolderUpsert(fresh)
	if b := pendingBatch(p); len(b.Deletes) != 0 || len(b.Upserts) != 1 {
		t.Fatalf("fresh evidence must supersede the delete: %+v", b)
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	p.MarkHolderUpsert(stale)
	if !p.dirtyEmpty() || !p.Tombstoned(stale.HolderKey(), stale.UpdatedAt) {
		t.Fatal("the superseded deletion fence must survive the fresh upsert's acknowledgement")
	}
}

// Tombstone retention is bounded by the holder budget as well as the TTL:
// under churn the oldest tombstones are forgotten first.
func TestRecentDeletesBoundedByHolderBudget(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 3})
	p.RetentionLimit = 3 // production never goes below one flush batch
	restoreForTest(t, p, now)
	for i := 0; i < 5; i++ {
		p.MarkHolderDelete(crs.HolderKey{Key: string(rune('a' + i)), CacheEpoch: "e"}, time.Now())
		if err := p.Flush(ctx); err != nil {
			t.Fatal(err)
		}
	}
	p.Mu.Lock()
	n, order := len(p.RecentDeletes), p.RecentOrder.Len()
	p.Mu.Unlock()
	if n != 3 || order != 3 {
		t.Fatalf("retention must stay within the holder budget: map=%d order=%d", n, order)
	}
	checkRetentionOrder(t, p)
	before := now.Add(-time.Minute)
	if p.Tombstoned(crs.HolderKey{Key: "a", CacheEpoch: "e"}, before) || !p.Tombstoned(crs.HolderKey{Key: "e", CacheEpoch: "e"}, before) {
		t.Fatal("the oldest tombstones must go first")
	}
	// A key decided again moves to the retention tail: with c, d, e kept,
	// deciding c again and then adding f and g must evict d and e, not c.
	time.Sleep(2 * time.Millisecond)
	p.MarkHolderDelete(crs.HolderKey{Key: "c", CacheEpoch: "e"}, time.Now())
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"f", "g"} {
		p.MarkHolderDelete(crs.HolderKey{Key: key, CacheEpoch: "e"}, time.Now())
		if err := p.Flush(ctx); err != nil {
			t.Fatal(err)
		}
	}
	p.Mu.Lock()
	n, order = len(p.RecentDeletes), p.RecentOrder.Len()
	p.Mu.Unlock()
	if n != 3 || order != 3 {
		t.Fatalf("retention must stay within the holder budget after refreshes: map=%d order=%d", n, order)
	}
	checkRetentionOrder(t, p)
	if !p.Tombstoned(crs.HolderKey{Key: "c", CacheEpoch: "e"}, before) || p.Tombstoned(crs.HolderKey{Key: "d", CacheEpoch: "e"}, before) {
		t.Fatal("a refreshed decision must outlive older ones")
	}
}

// A delete whose write failed is pending with its original decision time:
// a receipt newer than that decision still cancels it, and one older than it
// is still rejected, exactly as before the failure.
func TestFailedDeleteWriteKeepsTheDecisionTime(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	flaky := &flakyStore{Store: mem}
	ctx := context.Background()
	now := time.Now()
	p := New(flaky, nil, Options{MaxPending: 10})
	restoreForTest(t, p, now)
	k := crs.HolderKey{Key: "a", CacheEpoch: "e"}
	decided := now
	p.MarkHolderDelete(k, decided)
	flaky.broken = true
	if err := p.Flush(ctx); err == nil {
		t.Fatal("flush must report the failed delete")
	}
	p.Mu.Lock()
	change, pending := p.HolderDeletes[k]
	at := change.DeletedAt
	p.Mu.Unlock()
	if !pending || !at.Equal(decided) {
		t.Fatalf("pending delete must keep its decision time: pending=%v at=%v want %v", pending, at, decided)
	}
	if !p.Tombstoned(k, decided.Add(-time.Millisecond)) || p.Tombstoned(k, decided.Add(time.Millisecond)) {
		t.Fatal("the tombstone window must not move with the retry")
	}
	// Evidence newer than the decision re-proves the row and supersedes the
	// pending delete; the retried flush then writes the row.
	fresh := rec("a", "e", decided.Add(time.Millisecond), time.Minute)
	p.MarkHolderUpsert(fresh)
	flaky.broken = false
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	// Read a second later: the row's update time is just after the decision.
	if rows, _ := mem.LoadCacheHolders(ctx, now.Add(time.Second), 0, 0); len(rows) != 1 {
		t.Fatalf("re-proved row must be written, not deleted: %+v", rows)
	}
	if s := p.Status(); s.StaleUpserts != 0 {
		t.Fatalf("a receipt newer than the decision is not stale: %+v", s)
	}
}

// A delete decided again during an earlier write keeps the later decision
// pending whether that earlier write succeeds or fails.
func TestDeleteWriteKeepsTheLaterDecision(t *testing.T) {
	for _, succeeds := range []bool{true, false} {
		t.Run(fmt.Sprintf("succeeds_%v", succeeds), func(t *testing.T) {
			mem := memory.NewMemory(store.Config{})
			st := &deleteHookStore{Store: mem, passThrough: succeeds}
			now := time.Now()
			p := New(st, nil, Options{MaxPending: 10})
			restoreForTest(t, p, now)
			k := crs.HolderKey{Key: "a", CacheEpoch: "e"}
			second := now.Add(time.Second)
			p.MarkHolderDelete(k, now)
			st.onFirstDelete = func() { p.MarkHolderDelete(k, second) }
			err := p.Flush(context.Background())
			if (err == nil) != succeeds {
				t.Fatalf("unexpected write outcome: %v", err)
			}
			p.Mu.Lock()
			pending, exists := p.HolderDeletes[k]
			p.Mu.Unlock()
			if !exists || !pending.DeletedAt.Equal(second) {
				t.Fatalf("an old write must leave the later decision pending: %+v", pending)
			}
			p.MarkHolderDelete(k, now)
			if !p.Tombstoned(k, now.Add(500*time.Millisecond)) {
				t.Fatal("a delayed earlier decision must not move the fence backwards")
			}
			if err := p.Flush(context.Background()); err != nil {
				t.Fatal(err)
			}
			if !p.dirtyEmpty() || !p.Tombstoned(k, now.Add(500*time.Millisecond)) {
				t.Fatal("the later fence must remain after acknowledgement")
			}
		})
	}
}

// Retention evicts by decision time whatever order the decisions were
// recorded in: a newer tombstone is never forgotten before an older one.
func TestRecentDeletesEvictOldestDecisionFirst(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 2})
	p.RetentionLimit = 2
	now := time.Now()
	keys := []string{"c", "a", "b"}
	times := []time.Time{now.Add(3 * time.Second), now.Add(1 * time.Second), now.Add(2 * time.Second)}
	for i, k := range keys { // recorded out of time order, as one flush may
		rememberDelete(t, p, crs.HolderKey{Key: k, CacheEpoch: "e"}, times[i])
	}
	before := now
	if p.Tombstoned(crs.HolderKey{Key: "a", CacheEpoch: "e"}, before) {
		t.Fatal("the oldest decision (a) must be the one evicted")
	}
	for _, k := range []string{"b", "c"} {
		if !p.Tombstoned(crs.HolderKey{Key: k, CacheEpoch: "e"}, before) {
			t.Fatalf("newer decision %s must be retained", k)
		}
	}
}

// A delete decision discards the parked copy it outranks at once, and a row
// parked after the decision with older evidence is refused while the
// decision is pending or retained, so a copy parked before the decision
// never depends on the bounded tombstone retention to stay unbound.
func TestDeleteDecisionDiscardsOutrankedParkedCopy(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	restoreForTest(t, p, time.Now())
	now := time.Now()
	older := rec("a", "e", now.Add(-time.Second), time.Minute)
	p.Park(older)
	if s := p.Status(); s.PendingHolders != 1 {
		t.Fatalf("parked: %+v", s)
	}
	// Park, then decide: the parked copy goes with the decision.
	p.MarkHolderDelete(older.HolderKey(), now)
	if s := p.Status(); s.PendingHolders != 0 || s.DroppedPending != 1 {
		t.Fatalf("a decision must discard the parked copy it outranks: %+v", s)
	}
	// Decide, then park older evidence: refused. Newer evidence: kept.
	p.Park(older)
	if s := p.Status(); s.PendingHolders != 0 || s.DroppedPending != 2 {
		t.Fatalf("older evidence must not park behind a decision: %+v", s)
	}
	newer := rec("a", "e", now.Add(time.Second), time.Minute)
	p.Park(newer)
	if s := p.Status(); s.PendingHolders != 1 {
		t.Fatalf("newer evidence parks: %+v", s)
	}
	rows, _ := p.Take("e", "model", 0)
	if len(rows) != 1 || !rows[0].UpdatedAt.Equal(newer.UpdatedAt) {
		t.Fatalf("only the newer copy remains parked: %+v", rows)
	}
	if p.HasPending() {
		t.Fatal("take must clear the identity index too")
	}
	// The accepted residual: once a written decision has been evicted from
	// the count-bounded retention, evidence older than it can park again
	// (it can only exist through a receipt sampled before the decision and
	// never re-proved since); the resulting hint self-heals on the next
	// miss. Documented here so the bound is not mistaken for a guarantee.
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	p.RetentionLimit = 1
	rememberDelete(t, p, crs.HolderKey{Key: "b", CacheEpoch: "e"}, now.Add(2*time.Second))
	rememberDelete(t, p, crs.HolderKey{Key: "c", CacheEpoch: "e"}, now.Add(3*time.Second))
	p.Park(older)
	if s := p.Status(); s.PendingHolders != 1 {
		t.Fatalf("residual: a forgotten decision no longer refuses older evidence: %+v", s)
	}
}

// A prune forgets only the decisions older than the TTL, oldest first, in
// bounded chunks per lock hold; a refreshed decision moves in the order
// instead of leaving a stale entry behind.
func TestPruneForgetsExpiredDecisionsInChunks(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 100_000})
	now := time.Now()
	const old, fresh = 2*pruneBatchRows + 7, 100
	for i := 0; i < old; i++ {
		rememberDelete(t, p, crs.HolderKey{Key: fmt.Sprintf("o%05d", i), CacheEpoch: "e"}, now.Add(-2*time.Minute))
	}
	for i := 0; i < fresh; i++ {
		rememberDelete(t, p, crs.HolderKey{Key: fmt.Sprintf("f%05d", i), CacheEpoch: "e"}, now)
	}
	// Decided again, later: the entry moves to the fresh end. Decided again,
	// earlier: ignored, the later decision stands.
	rememberDelete(t, p, crs.HolderKey{Key: "o00000", CacheEpoch: "e"}, now)
	rememberDelete(t, p, crs.HolderKey{Key: "f00000", CacheEpoch: "e"}, now.Add(-3*time.Minute))
	p.Mu.Lock()
	if at := p.RecentDeletes[crs.HolderKey{Key: "f00000", CacheEpoch: "e"}]; !at.Equal(now) {
		t.Fatalf("an earlier re-decision must not move a retained decision back: %v", at)
	}
	p.Mu.Unlock()
	checkRetentionOrder(t, p)
	// One lock hold forgets at most its chunk and reports the rest.
	p.Mu.Lock()
	more := p.ForgetDecisionsBatch(now, time.Minute, 5)
	kept := len(p.RecentDeletes)
	p.Mu.Unlock()
	if !more || kept != old+fresh-5 {
		t.Fatalf("a bounded chunk must forget exactly its chunk and report more: more=%v kept=%d", more, kept)
	}
	checkRetentionOrder(t, p)
	p.Prune(context.Background(), now, time.Minute) // not ready: in-process prunes only
	checkRetentionOrder(t, p)
	p.Mu.Lock()
	kept = len(p.RecentDeletes)
	_, refreshed := p.RecentDeletes[crs.HolderKey{Key: "o00000", CacheEpoch: "e"}]
	p.Mu.Unlock()
	if kept != fresh+1 || !refreshed {
		t.Fatalf("a prune must forget exactly the expired decisions: kept=%d refreshed=%v", kept, refreshed)
	}
}

// An overflow during a failing delete write preserves the invalidation fence
// even though the reset replaces the per-row backlog.
func TestInFlightDeleteOverflowKeepsItsFence(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	st := &deleteHookStore{Store: mem}
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 2})
	restoreForTest(t, p, now)
	victim := rec("victim", "e", now, time.Minute)
	if err := mem.UpsertCacheHolders(context.Background(), []crs.HolderRecord{victim}); err != nil {
		t.Fatal(err)
	}
	p.MarkHolderDelete(victim.HolderKey(), now.Add(time.Second))
	st.onFirstDelete = func() {
		for i := 0; i < p.DirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(context.Background()); err == nil {
		t.Fatal("delete must fail")
	}
	if !p.Tombstoned(victim.HolderKey(), victim.UpdatedAt) || p.Status().OverflowResets != 1 {
		t.Fatal("overflow must retain the in-flight decision through its cutoff")
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(context.Background(), now, 0, 0); len(rows) != 0 {
		t.Fatalf("reset must remove the invalidated row: %+v", rows)
	}
}

// Timestamp ties go to the delete decision, whether pending or retained.
func TestDeleteDecisionWinsTimestampTies(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	now := time.Now()
	restoreForTest(t, p, now)
	k := crs.HolderKey{Key: "a", CacheEpoch: "e"}
	p.MarkHolderDelete(k, now)
	same := rec("a", "e", now, time.Minute) // sampled the same clock value
	p.MarkHolderUpsert(same)
	if b := pendingBatch(p); len(b.Deletes) != 1 || len(b.Upserts) != 0 {
		t.Fatalf("an equal-time receipt must not cancel the decision: %+v %+v", b.Deletes, b.Upserts)
	}
	if !p.Tombstoned(k, now) {
		t.Fatal("an equal-time row is tombstoned while the delete is pending")
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !p.Tombstoned(k, now) {
		t.Fatal("an equal-time row is tombstoned after the delete was acknowledged")
	}
	p.MarkHolderUpsert(same)
	if !p.dirtyEmpty() {
		t.Fatal("an equal-time receipt must not be queued after the delete was acknowledged")
	}
	if p.Tombstoned(k, now.Add(time.Nanosecond)) {
		t.Fatal("evidence strictly after the decision is not tombstoned")
	}
}
