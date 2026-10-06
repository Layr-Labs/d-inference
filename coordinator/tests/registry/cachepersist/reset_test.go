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

// A delete is never dropped at the dirty cap: the decision that overflows
// the backlog during a store outage discards the whole durable copy at the
// next flush, so a restart cannot restore the row it condemned, and a
// restore that runs after an overflow resets instead of loading.
func TestDeleteBacklogOverflowResetsDurableCopy(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	st := &resetCountingStore{Store: mem}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	stale := rec("stale", "e", now, time.Minute)
	p.MarkHolderUpsert(stale)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	// The store goes away; deletes fill the budget, and the row's own
	// decision is the one that overflows it: the one a cap would drop.
	for i := 0; i < p.DirtyCap; i++ {
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	p.MarkHolderDelete(stale.HolderKey(), now.Add(time.Second))
	if s := p.Status(); s.OverflowResets != 1 || s.DroppedDirty != 0 {
		t.Fatalf("an overflowing delete backlog must schedule a reset, not drop: %+v", s)
	}
	p.Mu.Lock()
	queued, pending := len(p.HolderDeletes), p.ResetPending
	p.Mu.Unlock()
	if queued != 1 || !pending {
		t.Fatalf("the overflow must release the backlog and queue the new decision: queued=%d pending=%v", queued, pending)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 || st.resets != 1 {
		t.Fatalf("the reset must remove the row the overflowing delete condemned: rows=%+v resets=%d", rows, st.resets)
	}
	fresh := rec("fresh", "e", now.Add(2*time.Second), time.Minute)
	p.MarkHolderUpsert(fresh)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 1 || rows[0].Key != "fresh" || st.resets != 1 {
		t.Fatalf("evidence after the reset must be written, without another reset: rows=%+v resets=%d", rows, st.resets)
	}
	// An overflow before any restore succeeded, the seeded row's own
	// decision overflowing: the restore resets instead of loading the row.
	seeded := rec("seeded", "e", now.Add(2*time.Second), time.Minute)
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{seeded}); err != nil {
		t.Fatal(err)
	}
	next := New(st, nil, Options{MaxPending: 2})
	for i := 0; i < next.DirtyCap; i++ {
		next.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("x%03d", i), CacheEpoch: "e"}, now.Add(3*time.Second))
	}
	next.MarkHolderDelete(seeded.HolderKey(), now.Add(3*time.Second))
	restoreForTest(t, next, now)
	if s := next.Status(); s.RestoredHolders != 0 || s.OverflowResets != 1 || !s.Ready || st.resets != 2 {
		t.Fatalf("a restore after an overflow must reset, not load: %+v resets=%d", s, st.resets)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 {
		t.Fatalf("the restore-time reset must empty the store: %+v", rows)
	}
	if err := next.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	next.Mu.Lock()
	pending = next.ResetPending
	next.Mu.Unlock()
	if s := next.Status(); st.resets != 2 || pending || s.FlushErrors != 0 {
		t.Fatalf("the restore-time reset must not be repeated by the flush: resets=%d pending=%v %+v", st.resets, pending, s)
	}
}

// A flush whose reset leaves nothing to snapshot still counts as a flush, so
// a reset-only flush is visible in the health counters.
func TestResetOnlyFlushIsCounted(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	for i := 0; i <= p.DirtyCap; i++ { // the last one overflows
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	// The overflowing decision is written and acknowledged after the reset;
	// a second flush with a reset and nothing behind it must still be counted.
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.Mu.Lock()
	p.ResetPending = true
	p.Mu.Unlock()
	before := p.Status()
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.Flushes != before.Flushes+1 || s.LastFlushAt == "" {
		t.Fatalf("a reset-only flush must be counted: before=%+v after=%+v", before, s)
	}
}

// An overflow that lands after the snapshot, while the batch is being written,
// discards the pre-overflow upserts and stops the flush before its next chunk.
// The reset runs in that same flush.
func TestFlushStopsWritingUpsertsWhenTheBacklogOverflowsAfterTheSnapshot(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	hook := &upsertHookStore{Store: mem, passThrough: true}
	st := &resetCountingStore{Store: hook}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 200}) // dirty cap 800: room for two chunks of upserts
	restoreForTest(t, p, now)
	const n = crs.BatchRows + 1 // two chunks
	for i := 0; i < n; i++ {
		p.MarkHolderUpsert(rec(fmt.Sprintf("u%04d", i), "e", now, time.Minute))
	}
	hook.onFirstUpsert = func() {
		// During the first chunk's write: the backlog overflows.
		for i := 0; i <= p.DirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.Mu.Lock()
	pending, queued := p.ResetPending, len(p.HolderUpserts)
	p.Mu.Unlock()
	rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0)
	if s := p.Status(); len(rows) != 0 || st.resets != 1 || pending || queued != 0 || s.DroppedDirty != n || s.FlushErrors != 0 {
		t.Fatalf("an overflow after the snapshot must stop further writes, discard pre-overflow upserts and reset in the same flush: rows=%d resets=%d pending=%v queued=%d %+v", len(rows), st.resets, pending, queued, s)
	}
}

// An upsert snapshotted before a backlog overflow must not survive as pending:
// its row may be one a released decision condemned, and retrying the upsert
// after the reset would write it back.
func TestUpsertsSnapshottedBeforeAnOverflowAreDiscarded(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	st := &upsertHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	condemned := rec("condemned", "e", now, time.Minute)
	p.MarkHolderUpsert(condemned)
	st.onFirstUpsert = func() {
		// While the batch is in flight: the row is invalidated, then the
		// backlog overflows and releases that decision.
		p.MarkHolderDelete(condemned.HolderKey(), now.Add(time.Second))
		for i := 0; i < p.DirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(ctx); err == nil {
		t.Fatal("the first upsert batch must fail")
	}
	p.Mu.Lock()
	_, pending := p.HolderUpserts[condemned.HolderKey()]
	p.Mu.Unlock()
	if s := p.Status(); pending || !p.Tombstoned(condemned.HolderKey(), condemned.UpdatedAt) || s.OverflowResets != 1 {
		t.Fatalf("an upsert snapshotted before the overflow must not be pending: pending=%v %+v", pending, s)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 {
		t.Fatalf("the condemned row must not be written back after the reset: %+v", rows)
	}
}

// A failed write after a handled overflow leaves its snapshot's mutations
// pending: the fence keys on the snapshot's overflow count, not on whether
// an overflow ever happened.
func TestUpsertsAfterAHandledOverflowRemainPendingOnFailure(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	st := &upsertHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	for i := 0; i <= p.DirtyCap; i++ { // the last one overflows
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	if err := p.Flush(ctx); err != nil { // the reset lands
		t.Fatal(err)
	}
	live := rec("live", "e", now.Add(2*time.Second), time.Minute)
	p.MarkHolderUpsert(live)
	st.onFirstUpsert = func() {} // the batch fails with no overflow in flight
	if err := p.Flush(ctx); err == nil {
		t.Fatal("the upsert batch must fail")
	}
	p.Mu.Lock()
	_, pending := p.HolderUpserts[live.HolderKey()]
	p.Mu.Unlock()
	if s := p.Status(); !pending || s.DroppedDirty != 0 {
		t.Fatalf("a failed upsert after the handled overflow must remain pending: pending=%v %+v", pending, s)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 1 || rows[0].Key != "live" {
		t.Fatalf("the pending upsert must reach the store: %+v", rows)
	}
}

// A snapshot never proceeds while a reset is pending: the check and the snapshot
// share one lock hold, so nothing snapshotted after an overflow can be written
// before the reset.
func TestSnapshotRefusesWhileAResetIsPending(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 2})
	restoreForTest(t, p, now)
	p.MarkHolderUpsert(rec("old", "e", now, time.Minute))
	for i := 0; i <= p.DirtyCap; i++ {
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	fresh := rec("fresh", "e", now.Add(2*time.Second), time.Minute)
	p.MarkHolderUpsert(fresh)
	if b, blocked := p.Snapshot(); !blocked || !b.Empty() {
		t.Fatalf("reset must atomically block snapshots: %+v blocked=%v", b, blocked)
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows, _ := mem.LoadCacheHolders(context.Background(), now.Add(3*time.Second), time.Minute, 0)
	if len(rows) != 1 || rows[0].Key != "fresh" {
		t.Fatalf("only fresh evidence may be written after reset: %+v", rows)
	}
}

// The fence runs before every store call, not only before upsert chunks: an
// overflow during a delete-only batch replaces the backlog, and the reset
// subsumes the remaining snapshotted deletes in that same flush.
func TestFlushStopsWritingDeletesWhenTheBacklogOverflowsAfterTheSnapshot(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	hook := &deleteHookStore{Store: mem, passThrough: true}
	st := &resetCountingStore{Store: hook}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 200}) // dirty cap 800: room for two chunks of deletes
	restoreForTest(t, p, now)
	const n = crs.BatchRows + 1 // two chunks
	for i := 0; i < n; i++ {
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("g%04d", i), CacheEpoch: "e"}, now)
	}
	hook.onFirstDelete = func() {
		// During the first chunk's write: fresh decisions overflow the
		// backlog, which still includes the unacknowledged snapshot.
		for i := 0; i <= p.DirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.Mu.Lock()
	pending, queued := p.ResetPending, len(p.HolderDeletes)
	p.Mu.Unlock()
	if s := p.Status(); st.resets != 1 || pending || s.RowsDeleted != crs.BatchRows || queued > p.DirtyCap || s.FlushErrors != 0 {
		t.Fatalf("an overflow during a delete-only batch must stop before the next chunk and reset in the same flush: resets=%d pending=%v queued=%d %+v", st.resets, pending, queued, s)
	}
}

// A reset that fails on the mid-flush path is counted once against that
// flush and retried by the next, which then writes the pending deletes.
func TestFlushRetriesAFailedResetAfterAMidFlushOverflow(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	hook := &upsertHookStore{Store: mem, passThrough: true}
	st := &resetCountingStore{Store: hook}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 200}) // dirty cap 800
	restoreForTest(t, p, now)
	gone := rec("gone", "e", now, time.Minute)
	p.MarkHolderUpsert(gone)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.MarkHolderDelete(gone.HolderKey(), now.Add(time.Second))
	const n = crs.BatchRows + 1 // two chunks of upserts ahead of the delete
	for i := 0; i < n; i++ {
		p.MarkHolderUpsert(rec(fmt.Sprintf("u%04d", i), "e", now.Add(time.Second), time.Minute))
	}
	hook.onFirstUpsert = func() {
		for i := 0; i <= p.DirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(2*time.Second))
		}
		st.failNext = 1 // the reset this flush attempts fails, slowly
		st.slow = 30 * time.Millisecond
	}
	stamped := p.Status().LastFlushAt
	if err := p.Flush(ctx); err == nil {
		t.Fatal("a failed reset must fail the flush")
	}
	p.Mu.Lock()
	pending := p.ResetPending
	_, hasDelete := p.HolderDeletes[gone.HolderKey()]
	p.Mu.Unlock()
	// The reset is part of the flush: its duration lands in the stamp.
	if s := p.Status(); st.resets != 1 || !pending || hasDelete || !p.Tombstoned(gone.HolderKey(), gone.UpdatedAt) || s.Flushes != 2 || s.FlushErrors != 1 || s.LastFlushAt < stamped || s.LastFlushMs < 30 {
		t.Fatalf("a failed mid-flush reset must be counted once and leave the reset pending and the invalidation fenced: resets=%d pending=%v has_delete=%v %+v", st.resets, pending, hasDelete, s)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.Mu.Lock()
	pending = p.ResetPending
	p.Mu.Unlock()
	rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0)
	if s := p.Status(); st.resets != 2 || pending || len(rows) != 0 || s.RowsDeleted == 0 || s.FlushErrors != 1 {
		t.Fatalf("the next flush must reset and write the pending deletes: resets=%d pending=%v rows=%d %+v", st.resets, pending, len(rows), s)
	}
}

// An overflow wakes the flush loop once, however many overflows pile up
// before it runs, and never blocks the mark.
func TestOverflowWakesTheFlushLoop(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 2}) // dirty cap 8
	select {
	case <-p.Wake():
		t.Fatal("no wake-up before an overflow")
	default:
	}
	for round := 0; round < 2; round++ { // two overflows, one token
		for i := 0; i <= p.DirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("r%d-%03d", round, i), CacheEpoch: "e"}, now)
		}
	}
	select {
	case <-p.Wake():
	default:
		t.Fatal("an overflow must wake the flush loop")
	}
	select {
	case <-p.Wake():
		t.Fatal("overflows before the loop ran must coalesce into one wake-up")
	default:
	}
	if s := p.Status(); s.OverflowResets != 2 {
		t.Fatalf("both overflows must be counted: %+v", s)
	}
}
