package cachepersist

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

type pendingRecords struct {
	upserts []crs.HolderRecord
	deletes []crs.HolderKey
	demand  []crs.DemandRecord
}

// pendingBatch inspects a bounded snapshot without mutating the write queue.
func pendingBatch(p *Persister) pendingRecords {
	b, _ := p.snapshot()
	var out pendingRecords
	for _, write := range b.upserts {
		out.upserts = append(out.upserts, write.record)
	}
	for _, write := range b.deletes {
		out.deletes = append(out.deletes, write.key)
	}
	for _, write := range b.demand {
		out.demand = append(out.demand, crs.DemandRecord{Key: write.key, SeenAt: write.seenAt})
	}
	return out
}

func (p *Persister) dirtyEmpty() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.holderUpserts)+len(p.holderDeletes)+len(p.demandTouched) == 0 && !p.resetPending
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
	p.mu.Lock()
	defer p.mu.Unlock()
	checkKeyedTimeHeap(t, "retention order", &p.recentOrder, len(p.recentDeletes), func(k crs.HolderKey) (time.Time, bool) {
		at, ok := p.recentDeletes[k]
		return at, ok
	})
}
