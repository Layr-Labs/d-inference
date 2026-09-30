package cachepersist

import (
	"container/heap"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// timedKey is one row identity with the time that orders it: a parked row's
// expiry, or a delete decision's time.
type timedKey struct {
	key crs.HolderKey
	at  time.Time
}

// keyedTimeHeap orders identities by time, soonest first, and indexes the
// entries by identity, so an entry moves when its time changes and leaves
// when its row leaves the set, in O(log n) each. It holds exactly one entry
// per key: nothing is ever stale, compacted or skipped, and a prune pops
// from the soonest end in bounded chunks.
type keyedTimeHeap struct {
	entries []timedKey
	pos     map[crs.HolderKey]int
}

func (h *keyedTimeHeap) Len() int           { return len(h.entries) }
func (h *keyedTimeHeap) Less(i, j int) bool { return h.entries[i].at.Before(h.entries[j].at) }
func (h *keyedTimeHeap) Swap(i, j int) {
	h.entries[i], h.entries[j] = h.entries[j], h.entries[i]
	h.pos[h.entries[i].key] = i
	h.pos[h.entries[j].key] = j
}
func (h *keyedTimeHeap) Push(x any) {
	e := x.(timedKey)
	h.pos[e.key] = len(h.entries)
	h.entries = append(h.entries, e)
}
func (h *keyedTimeHeap) Pop() any {
	old := h.entries
	n := len(old)
	e := old[n-1]
	old[n-1] = timedKey{}
	h.entries = old[:n-1]
	delete(h.pos, e.key)
	return e
}

// set records a key's time, moving its entry when it has one.
func (h *keyedTimeHeap) set(key crs.HolderKey, at time.Time) {
	if h.pos == nil {
		h.pos = make(map[crs.HolderKey]int)
	}
	if i, ok := h.pos[key]; ok {
		h.entries[i].at = at
		heap.Fix(h, i)
		return
	}
	heap.Push(h, timedKey{key: key, at: at})
}

// remove drops a key's entry, if it has one.
func (h *keyedTimeHeap) remove(key crs.HolderKey) {
	if i, ok := h.pos[key]; ok {
		heap.Remove(h, i)
	}
}

// soonest returns the entry with the earliest time.
func (h *keyedTimeHeap) soonest() (timedKey, bool) {
	if len(h.entries) == 0 {
		return timedKey{}, false
	}
	return h.entries[0], true
}
