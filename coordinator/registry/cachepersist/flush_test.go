package cachepersist

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestFlushRetriesUnwrittenRemainderAndDedupesDemand(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	flaky := &flakyStore{Store: mem, broken: true}
	p := New(flaky, nil, Options{MaxPending: 1000})
	now := time.Now()
	restoreForTest(t, p, now)
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
	if rows, _ := mem.LoadCacheHolders(context.Background(), now, 0, 0); len(rows) != 1 {
		t.Fatalf("pending holder not written: %d", len(rows))
	}
	if d, _ := mem.LoadCacheDemand(context.Background(), now.Add(-time.Minute), now.Add(time.Minute), 0); len(d) != 2 {
		t.Fatalf("pending demand not written: %d", len(d))
	}
	// Within the granularity window the same key is not written again.
	p.MarkDemand([]string{"d-1"}, now.Add(10*time.Second))
	if b := pendingBatch(p); len(b.demand) != 0 {
		t.Fatalf("demand key re-marked inside the granularity window: %+v", b.demand)
	}
	p.MarkDemand([]string{"d-1"}, now.Add(2*time.Minute))
	if b := pendingBatch(p); len(b.demand) != 1 {
		t.Fatalf("demand key not re-marked after the window: %+v", b.demand)
	}
}

func TestFlushWritesInBoundedChunksAndKeepsPartialProgress(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 100_000})
	now := time.Now()
	restoreForTest(t, p, now)
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
		t.Fatalf("FlushAll must write and acknowledge the remainder: %v", err)
	}
	if rows, _ := mem.LoadCacheHolders(context.Background(), now, 0, 0); len(rows) != HolderFlushRows+300 {
		t.Fatalf("rows written: %d", len(rows))
	}
}

// Nothing is written before Restore has established the key generation:
// the next boot would treat such rows as foreign and reset them.
func TestFlushWaitsForRestore(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 10, Fingerprint: "gen-1"})
	p.MarkHolderUpsert(rec("a", "e", now, time.Minute))
	p.MarkDemand([]string{"d"}, now)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if err := p.FlushAll(ctx); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.Ready || s.Flushes != 0 || s.RowsWritten != 0 || p.dirtyEmpty() {
		t.Fatalf("flush must be a no-op that keeps the marks while not ready: %+v", s)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, 0, 0); len(rows) != 0 {
		t.Fatalf("rows written before the generation was recorded: %+v", rows)
	}
	if _, err := p.Restore(ctx, now, time.Minute, 10, 10); err != nil {
		t.Fatal(err)
	}
	if !p.Ready() {
		t.Fatal("restore must mark the persister ready")
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.RowsWritten != 2 || !p.dirtyEmpty() {
		t.Fatalf("marks made before the restore must be written after it: %+v", s)
	}
	if fp, _ := mem.CacheRoutingKeyFingerprint(ctx); fp != "gen-1" {
		t.Fatalf("generation not recorded: %q", fp)
	}
}

// Receipt times are sampled before the tracker lock: a delayed older receipt
// for a row shared by overlapping sessions must not overwrite the newer
// evidence already queued for the same (key, epoch).
func TestMarkHolderUpsertKeepsTheNewerQueuedRecord(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	now := time.Now()
	newer := rec("a", "e", now, time.Minute)
	newer.StageMs = 900
	older := rec("a", "e", now.Add(-time.Second), 2*time.Minute) // longer stored lifetime, older evidence
	older.StageMs = 50
	p.MarkHolderUpsert(newer)
	p.MarkHolderUpsert(older)
	b := pendingBatch(p)
	if len(b.upserts) != 1 || b.upserts[0].StageMs != 900 || !b.upserts[0].UpdatedAt.Equal(now) ||
		!b.upserts[0].ExpiresAt.Equal(now.Add(-time.Second).Add(2*time.Minute)) {
		t.Fatalf("queued upsert must keep the newer record and the later expiry: %+v", b.upserts)
	}
}

// A failed write leaves the newest desired evidence pending, regardless
// of the order in which concurrent receipts arrived.
func TestFailedUpsertKeepsNewestEvidence(t *testing.T) {
	for _, newerFirst := range []bool{true, false} {
		t.Run(fmt.Sprintf("newer_first_%v", newerFirst), func(t *testing.T) {
			mem := memory.NewMemory(store.Config{})
			st := &upsertHookStore{Store: mem}
			now := time.Now()
			p := New(st, nil, Options{MaxPending: 10})
			restoreForTest(t, p, now)
			newer, older := rec("a", "e", now, time.Minute), rec("a", "e", now.Add(-time.Second), time.Minute)
			newer.StageMs, older.StageMs = 900, 50
			first, second := older, newer
			if newerFirst {
				first, second = newer, older
			}
			p.MarkHolderUpsert(first)
			st.onFirstUpsert = func() { p.MarkHolderUpsert(second) }
			if err := p.Flush(context.Background()); err == nil {
				t.Fatal("write must fail")
			}
			if b := pendingBatch(p); len(b.upserts) != 1 || b.upserts[0].StageMs != 900 {
				t.Fatalf("newest evidence must stay pending: %+v", b.upserts)
			}
			if err := p.Flush(context.Background()); err != nil {
				t.Fatal(err)
			}
			rows, _ := mem.LoadCacheHolders(context.Background(), now, 0, 0)
			if len(rows) != 1 || rows[0].StageMs != 900 {
				t.Fatalf("retry must write newest evidence: %+v", rows)
			}
		})
	}
}
