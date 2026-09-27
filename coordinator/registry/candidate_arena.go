package registry

// candidate_arena.go — chunked storage for the routing scan's candidates.
//
// scanCandidatesLocked used to heap-allocate one routingCandidate per
// eligible provider (~250 per request at fleet scale, each carrying a ~600
// byte snapshot that had already been copied twice on the way in). An arena
// hands out slots from chunks of candidateArenaChunk candidates, so the scan
// performs one allocation per chunk and every snapshot is written in place.
//
// Pointer stability: a chunk is never grown or moved once handed out, so
// pointers into it (the candidate pool, the winner, the DispatchPlan's
// retained alternates) stay valid for as long as they are referenced — the
// GC keeps the whole chunk alive with them. The scan pool's "immutable value
// snapshots" contract is unchanged: nothing writes a slot after it is
// appended to the pool.

// candidateArenaChunk is the number of candidates per chunk. 32 × ~650 bytes
// keeps a chunk around 20 KiB (below the large-object threshold) while a
// fleet-scale scan of ~250 candidates needs ~8 allocations.
const candidateArenaChunk = 32

// candidateArena is a bump allocator over chunks of routingCandidate. The
// zero value is ready to use; it is single-goroutine (one per scan).
type candidateArena struct {
	chunk []routingCandidate
}

// next returns a zeroed slot. The slot belongs to the caller until release
// hands it back or the caller keeps it (appends it to the pool).
func (a *candidateArena) next() *routingCandidate {
	if len(a.chunk) == cap(a.chunk) {
		a.chunk = make([]routingCandidate, 0, candidateArenaChunk)
	}
	a.chunk = a.chunk[:len(a.chunk)+1]
	c := &a.chunk[len(a.chunk)-1]
	*c = routingCandidate{}
	return c
}

// release hands back the slot most recently returned by next so the next
// call reuses it (a provider rejected after its snapshot was built). Any
// other pointer is ignored — a kept slot is never reclaimed.
func (a *candidateArena) release(c *routingCandidate) {
	if n := len(a.chunk); n > 0 && &a.chunk[n-1] == c {
		a.chunk = a.chunk[:n-1]
	}
}
