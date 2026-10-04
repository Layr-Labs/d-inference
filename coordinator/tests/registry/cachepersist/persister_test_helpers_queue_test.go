package cachepersist_test

import (
	"testing"
	"time"

	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// checkKeyedTimeHeap asserts an order holds exactly one entry per key of
// the set it indexes (count keys), each at the position its index records,
// with the time the set currently holds for it: the invariant that lets a
// take, a drop, a merge or a refresh touch one entry instead of leaving
// stale ones for a later scan. Called with p.Mu held.
func checkKeyedTimeHeap(t *testing.T, name string, h *cachequeue.TimeOrder, count int, timeOf func(crs.HolderKey) (time.Time, bool)) {
	t.Helper()
	if n := h.Len(); n != count || len(h.Pos) != n {
		t.Fatalf("%s out of step with its set: entries=%d indexed=%d keys=%d", name, n, len(h.Pos), count)
	}
	for i, e := range h.Entries {
		if h.Pos[e.Key] != i {
			t.Fatalf("%s: entry %d for %v indexed at %d", name, i, e.Key, h.Pos[e.Key])
		}
		if at, ok := timeOf(e.Key); !ok || !at.Equal(e.At) {
			t.Fatalf("%s: entry for %v names a missing key or a stale time (present=%v entry=%v set=%v)", name, e.Key, ok, e.At, at)
		}
	}
}
