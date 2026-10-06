package candidatearena

// Arena keeps scan candidate pointers stable across chunk allocations. Public
// scans own their chunks through ordinary GC reachability. Private reservations
// can borrow Storage exclusively until every scan reader finishes; their plans
// retain copied quotes and provider identities. Full admission and forecast
// snapshots remain in transient evaluation storage.

// ChunkSize is the most routing candidates that fit the allocator's largest
// small-object size class (32 KiB). One fewer is rounded up to the same class
// and wastes the tail; one more makes each chunk a large object. Each chunk retains stable
// pointers until the scan and its retained candidates are no longer referenced.
const ChunkSize = 55

// Arena is a bump allocator over chunks of request-local candidates. The
// zero value is ready to use; it is single-goroutine (one per scan).
// Non-nil Storage must be exclusively owned until this scan's readers finish.
type Arena[T any] struct {
	chunk   []T
	Storage *Storage[T]
}

// Next returns a zeroed slot. The slot belongs to the caller until Release
// hands it back or the caller keeps it (appends it to the pool).
func (a *Arena[T]) Next() *T {
	if len(a.chunk) == cap(a.chunk) {
		if a.Storage == nil {
			a.chunk = make([]T, 0, ChunkSize)
		} else {
			a.chunk = a.Storage.chunk()
		}
	}
	a.chunk = a.chunk[:len(a.chunk)+1]
	// New chunks and reset borrowed chunks are zeroed; Release clears the only
	// slot that may be handed out twice during this scan.
	return &a.chunk[len(a.chunk)-1]
}

// Release hands back the slot most recently returned by Next so the next
// call reuses it (a provider rejected after its snapshot was built). Any
// other pointer is ignored — a kept slot is never reclaimed.
func (a *Arena[T]) Release(c *T) {
	if n := len(a.chunk); n > 0 && &a.chunk[n-1] == c {
		var zero T
		*c = zero
		a.chunk = a.chunk[:n-1]
	}
}
