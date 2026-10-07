package cachepersist

import (
	"container/heap"
	"time"

	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// setTime records a key's time, moving its entry when it has one.
func setTime(h *cachequeue.TimeOrder, key crs.HolderKey, at time.Time) {
	if h.Pos == nil {
		h.Pos = make(map[crs.HolderKey]int)
	}
	if i, ok := h.Pos[key]; ok {
		h.Entries[i].At = at
		heap.Fix(h, i)
		return
	}
	heap.Push(h, cachequeue.TimedKey{Key: key, At: at})
}
