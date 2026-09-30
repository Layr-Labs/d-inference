package cachepersist

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

func TestUpsertAcknowledgementKeepsConcurrentMutation(t *testing.T) {
	for _, invalidate := range []bool{false, true} {
		t.Run(fmt.Sprintf("invalidate_%v", invalidate), func(t *testing.T) {
			ctx, now := context.Background(), time.Now()
			mem := store.NewMemory(store.Config{})
			hook := &upsertHookStore{Store: mem, passThrough: true}
			p := New(hook, nil, Options{MaxPending: 10})
			restoreForTest(t, p, now)
			old := rec("a", "e", now, time.Minute)
			fresh := rec("a", "e", now.Add(time.Second), time.Minute)
			fresh.StageMs = 900
			p.MarkHolderUpsert(old)
			hook.onFirstUpsert = func() {
				if invalidate {
					p.MarkHolderDelete(old.HolderKey(), fresh.UpdatedAt)
				} else {
					p.MarkHolderUpsert(fresh)
				}
			}
			if err := p.Flush(ctx); err != nil {
				t.Fatal(err)
			}
			if p.dirtyEmpty() {
				t.Fatal("acknowledging the old write cleared a concurrent mutation")
			}
			if err := p.FlushAll(ctx); err != nil {
				t.Fatal(err)
			}
			rows, err := mem.LoadCacheHolders(ctx, now.Add(2*time.Second), time.Minute, 0)
			if err != nil {
				t.Fatal(err)
			}
			if invalidate {
				if len(rows) != 0 {
					t.Fatalf("concurrent invalidation did not reach the store: %+v", rows)
				}
			} else if len(rows) != 1 || rows[0].StageMs != fresh.StageMs {
				t.Fatalf("concurrent fresh evidence did not reach the store: %+v", rows)
			}
		})
	}
}

func TestDeleteAcknowledgementKeepsConcurrentFreshEvidence(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	mem := store.NewMemory(store.Config{})
	hook := &deleteHookStore{Store: mem, passThrough: true}
	p := New(hook, nil, Options{MaxPending: 10})
	restoreForTest(t, p, now)
	old := rec("a", "e", now, time.Minute)
	fresh := rec("a", "e", now.Add(2*time.Second), time.Minute)
	p.MarkHolderUpsert(old)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.MarkHolderDelete(old.HolderKey(), now.Add(time.Second))
	hook.onFirstDelete = func() { p.MarkHolderUpsert(fresh) }
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if p.dirtyEmpty() {
		t.Fatal("acknowledging the delete cleared newer evidence")
	}
	if err := p.FlushAll(ctx); err != nil {
		t.Fatal(err)
	}
	rows, err := mem.LoadCacheHolders(ctx, now.Add(3*time.Second), time.Minute, 0)
	if err != nil || len(rows) != 1 || !rows[0].UpdatedAt.Equal(fresh.UpdatedAt) {
		t.Fatalf("fresh evidence was lost: %+v %v", rows, err)
	}
}

type demandHookStore struct {
	crs.Store
	onFirstDemand func()
}

func (s *demandHookStore) UpsertCacheDemand(ctx context.Context, rows []crs.DemandRecord) error {
	if hook := s.onFirstDemand; hook != nil {
		s.onFirstDemand = nil
		hook()
	}
	return s.Store.UpsertCacheDemand(ctx, rows)
}

func TestDemandAcknowledgementKeepsConcurrentObservation(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	mem := store.NewMemory(store.Config{})
	hook := &demandHookStore{Store: mem}
	p := New(hook, nil, Options{MaxPending: 10})
	restoreForTest(t, p, now)
	newest := now.Add(2 * time.Minute)
	p.MarkDemand([]string{"d"}, now)
	hook.onFirstDemand = func() { p.MarkDemand([]string{"d"}, newest) }
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if p.dirtyEmpty() {
		t.Fatal("acknowledging an observation cleared a newer one")
	}
	if err := p.FlushAll(ctx); err != nil {
		t.Fatal(err)
	}
	rows, err := mem.LoadCacheDemand(ctx, now.Add(-time.Minute), newest, 0)
	if err != nil || len(rows) != 1 || !rows[0].SeenAt.Equal(newest) {
		t.Fatalf("newer demand observation was lost: %+v %v", rows, err)
	}
}

type chunkFailureStore struct {
	crs.Store
	calls   int
	written int
}

func (s *chunkFailureStore) UpsertCacheHolders(ctx context.Context, rows []crs.HolderRecord) error {
	s.calls++
	if s.calls == 2 {
		return errors.New("second chunk failed")
	}
	if err := s.Store.UpsertCacheHolders(ctx, rows); err != nil {
		return err
	}
	s.written += len(rows)
	return nil
}

func TestFailedChunkRetriesOnlyUnacknowledgedRows(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	mem := store.NewMemory(store.Config{})
	st := &chunkFailureStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 1000})
	restoreForTest(t, p, now)
	const n = 2*crs.BatchRows + 3
	for i := 0; i < n; i++ {
		p.MarkHolderUpsert(rec(fmt.Sprintf("k%d", i), "e", now, time.Minute))
	}
	if err := p.Flush(ctx); err == nil {
		t.Fatal("second chunk must fail")
	}
	if st.written != crs.BatchRows || len(pendingBatch(p).upserts) != n-crs.BatchRows {
		t.Fatal("successful first chunk was not acknowledged independently")
	}
	if err := p.FlushAll(ctx); err != nil {
		t.Fatal(err)
	}
	rows, err := mem.LoadCacheHolders(ctx, now, time.Minute, 0)
	if err != nil || len(rows) != n || st.written != n {
		t.Fatalf("retry rewrote acknowledged rows or lost pending rows: rows=%d writes=%d err=%v", len(rows), st.written, err)
	}
}

func TestInFlightDeletesSurviveRetentionPressure(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	mem := store.NewMemory(store.Config{})
	hook := &deleteHookStore{Store: mem}
	p := New(hook, nil, Options{MaxPending: 1500})
	restoreForTest(t, p, now)
	const total = HolderFlushRows + 1000
	rows := make([]crs.HolderRecord, 0, total)
	for i := 0; i < total; i++ {
		r := rec(fmt.Sprintf("k%05d", i), "e", now.Add(-time.Second), time.Minute)
		rows = append(rows, r)
		p.MarkHolderDelete(r.HolderKey(), now.Add(time.Duration(i)*time.Nanosecond))
	}
	if err := mem.UpsertCacheHolders(ctx, rows); err != nil {
		t.Fatal(err)
	}
	// Fill the retained history; the remaining batch includes older decisions.
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	remaining := pendingBatch(p).deletes
	if len(remaining) != 1000 || len(p.recentDeletes) != p.retentionLimit {
		t.Fatal("test did not fill retention while leaving pending deletes")
	}
	hook.onFirstDelete = func() {
		for _, k := range remaining {
			p.MarkHolderUpsert(rec(k.Key, k.CacheEpoch, now.Add(-time.Second), time.Minute))
		}
	}
	if err := p.Flush(ctx); err == nil {
		t.Fatal("delete must fail")
	}
	if err := p.FlushAll(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, err := mem.LoadCacheHolders(ctx, now, 0, 0); err != nil || len(rows) != 0 {
		t.Fatalf("failed delete retry lost to stale evidence: rows=%+v err=%v", rows, err)
	}
	if s := p.Status(); s.RowsDeleted != total || s.OverflowResets != 0 || s.RowsWritten != 0 {
		t.Fatalf("pending deletes must survive without overflow or stale writes: %+v", s)
	}
}
