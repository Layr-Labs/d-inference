package candidatearena

// candidate_arena.go — chunked storage for the routing scan's candidates.
//
// scanCandidatesLocked used to heap-allocate one routingCandidate per
// eligible provider (~250 per request at fleet scale, each carrying a ~600
// byte snapshot that had already been copied twice on the way in). An arena
// hands out slots from chunks of ChunkSize candidates, so the scan
// performs one allocation per chunk and every snapshot is written in place.
//
// Pointer stability: a chunk is never grown or moved once handed out, so
// pointers into it (the candidate pool, the winner, the DispatchPlan's
// retained alternates) stay valid for as long as they are referenced — the
// GC keeps the whole chunk alive with them. The scan pool's "immutable value
// snapshots" contract is unchanged: nothing writes a slot after it is
// appended to the pool.

// ChunkSize is the most routing candidates that fit the allocator's largest
// small-object size class (32 KiB). One fewer is rounded up to the same class
// and wastes the tail; one more makes each chunk a large object. A fleet-scale
// scan of ~250 candidates needs ~12 allocations while retaining stable
// pointers into each chunk.
const ChunkSize = 22

// Arena is a bump allocator over chunks of request-local candidates. The
// zero value is ready to use; it is single-goroutine (one per scan).
type Arena[T any] struct {
	chunk []T
}

// Next returns a zeroed slot. The slot belongs to the caller until Release
// hands it back or the caller keeps it (appends it to the pool).
func (a *Arena[T]) Next() *T {
	if len(a.chunk) == cap(a.chunk) {
		a.chunk = make([]T, 0, ChunkSize)
	}
	a.chunk = a.chunk[:len(a.chunk)+1]
	c := &a.chunk[len(a.chunk)-1]
	var zero T
	*c = zero
	return c
}

// Release hands back the slot most recently returned by Next so the next
// call reuses it (a provider rejected after its snapshot was built). Any
// other pointer is ignored — a kept slot is never reclaimed.
func (a *Arena[T]) Release(c *T) {
	if n := len(a.chunk); n > 0 && &a.chunk[n-1] == c {
		a.chunk = a.chunk[:n-1]
	}
}
