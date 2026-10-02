package cachepersist

import (
	"context"
	"testing"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// restoreForTest records the key generation so writes are unblocked, as the
// boot restore does in production.
func restoreForTest(t *testing.T, p *Persister, now time.Time) {
	t.Helper()
	if _, err := p.Restore(context.Background(), now, time.Minute, 1000, 0); err != nil {
		t.Fatalf("restore: %v", err)
	}
}

func rec(key, epoch string, now time.Time, ttl time.Duration) crs.HolderRecord {
	return crs.HolderRecord{Key: key, CacheEpoch: epoch, Tier: "ssd", ModelID: "model",
		AnchorTokenCount: 1024, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(ttl)}
}

// checkKeyedTimeHeap asserts an order holds exactly one entry per key of
// the set it indexes (count keys), each at the position its index records,
// with the time the set currently holds for it: the invariant that lets a
// take, a drop, a merge or a refresh touch one entry instead of leaving
// stale ones for a later scan. Called with p.mu held.
func checkKeyedTimeHeap(t *testing.T, name string, h *keyedTimeHeap, count int, timeOf func(crs.HolderKey) (time.Time, bool)) {
	t.Helper()
	if n := h.Len(); n != count || len(h.pos) != n {
		t.Fatalf("%s out of step with its set: entries=%d indexed=%d keys=%d", name, n, len(h.pos), count)
	}
	for i, e := range h.entries {
		if h.pos[e.key] != i {
			t.Fatalf("%s: entry %d for %v indexed at %d", name, i, e.key, h.pos[e.key])
		}
		if at, ok := timeOf(e.key); !ok || !at.Equal(e.at) {
			t.Fatalf("%s: entry for %v names a missing key or a stale time (present=%v entry=%v set=%v)", name, e.key, ok, e.at, at)
		}
	}
}
