package cachepersist_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

type pendingRecords struct {
	Upserts []crs.HolderRecord
	Deletes []crs.HolderKey
	Demand  []crs.DemandRecord
}

// pendingBatch inspects a bounded snapshot without mutating the write queue.
func pendingBatch(p *Persister) pendingRecords {
	b, _ := p.Snapshot()
	var out pendingRecords
	for _, write := range b.Upserts {
		out.Upserts = append(out.Upserts, write.Record)
	}
	for _, write := range b.Deletes {
		out.Deletes = append(out.Deletes, write.Key)
	}
	for _, write := range b.Demand {
		out.Demand = append(out.Demand, crs.DemandRecord{Key: write.Key, SeenAt: write.SeenAt})
	}
	return out
}

func (p *Persister) dirtyEmpty() bool {
	p.Mu.Lock()
	defer p.Mu.Unlock()
	return len(p.HolderUpserts)+len(p.HolderDeletes)+len(p.DemandTouched) == 0 && !p.ResetPending
}

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

func (f *flakyStore) DeleteCacheHolders(ctx context.Context, k []crs.HolderKey) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.Store.DeleteCacheHolders(ctx, k)
}

func (f *flakyStore) UpsertCacheDemand(ctx context.Context, r []crs.DemandRecord) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.Store.UpsertCacheDemand(ctx, r)
}

// resetCountingStore counts the durable-copy resets a persister asks for.
type resetCountingStore struct {
	crs.Store
	resets   int           // attempts, failed ones included
	failNext int           // resets to fail before letting one through
	slow     time.Duration // how long each attempt takes
}

func (s *resetCountingStore) ResetCacheRoutingState(ctx context.Context, fingerprint string) error {
	s.resets++
	if s.slow > 0 {
		time.Sleep(s.slow)
	}
	if s.failNext > 0 {
		s.failNext--
		return fmt.Errorf("store unavailable")
	}
	return s.Store.ResetCacheRoutingState(ctx, fingerprint)
}

// deleteHookStore runs a hook during the first delete batch, before its
// acknowledgement, then fails the call unless passThrough is set.
type deleteHookStore struct {
	crs.Store
	onFirstDelete func()
	passThrough   bool
}

func (s *deleteHookStore) DeleteCacheHolders(ctx context.Context, keys []crs.HolderKey) error {
	if hook := s.onFirstDelete; hook != nil {
		s.onFirstDelete = nil
		hook()
		if !s.passThrough {
			return fmt.Errorf("store unavailable")
		}
	}
	return s.Store.DeleteCacheHolders(ctx, keys)
}

// upsertHookStore runs a hook during the first upsert batch (the window in
// which the batch is in flight) and then fails it, or lets it through when
// passThrough is set.
type upsertHookStore struct {
	crs.Store
	onFirstUpsert func()
	passThrough   bool
}

func (s *upsertHookStore) UpsertCacheHolders(ctx context.Context, rows []crs.HolderRecord) error {
	if hook := s.onFirstUpsert; hook != nil {
		s.onFirstUpsert = nil
		hook()
		if !s.passThrough {
			return fmt.Errorf("store unavailable")
		}
	}
	return s.Store.UpsertCacheHolders(ctx, rows)
}

// checkRetentionOrder asserts the retention order matches the retained
// decisions.
func checkRetentionOrder(t *testing.T, p *Persister) {
	t.Helper()
	p.Mu.Lock()
	defer p.Mu.Unlock()
	checkKeyedTimeHeap(t, "retention order", &p.RecentOrder, len(p.RecentDeletes), func(k crs.HolderKey) (time.Time, bool) {
		at, ok := p.RecentDeletes[k]
		return at, ok
	})
}
