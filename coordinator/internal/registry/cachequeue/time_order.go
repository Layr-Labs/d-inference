package cachequeue

import (
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// timedKey is one row identity with the time that orders it: a parked row's
// expiry, or a delete decision's time.
type TimedKey struct {
	Key crs.HolderKey
	At  time.Time
}

// keyedTimeHeap orders identities by time, soonest first, and indexes the
// entries by identity, so an entry moves when its time changes and leaves
// when its row leaves the set, in O(log n) each. It holds exactly one entry
// per key: nothing is ever stale, compacted or skipped, and a prune pops
// from the soonest end in bounded chunks.
type TimeOrder struct {
	Entries []TimedKey
	Pos     map[crs.HolderKey]int
}

func (h *TimeOrder) Len() int           { return len(h.Entries) }
func (h *TimeOrder) Less(i, j int) bool { return h.Entries[i].At.Before(h.Entries[j].At) }
func (h *TimeOrder) Swap(i, j int) {
	h.Entries[i], h.Entries[j] = h.Entries[j], h.Entries[i]
	h.Pos[h.Entries[i].Key] = i
	h.Pos[h.Entries[j].Key] = j
}
func (h *TimeOrder) Push(x any) {
	e := x.(TimedKey)
	h.Pos[e.Key] = len(h.Entries)
	h.Entries = append(h.Entries, e)
}
func (h *TimeOrder) Pop() any {
	old := h.Entries
	n := len(old)
	e := old[n-1]
	old[n-1] = TimedKey{}
	h.Entries = old[:n-1]
	delete(h.Pos, e.Key)
	return e
}
