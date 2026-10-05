package candidatearena

// MaxStorageChunks bounds retained storage per exclusive reservation borrower.
// Routing chunks fit within 32 KiB, so at most 2 MiB remains in each pooled
// object. sync.Pool may discard idle objects; this is not a global pool limit.
const MaxStorageChunks = 64
const MaxReusableCandidates = MaxStorageChunks * ChunkSize

// Storage is owned exclusively by one private reservation call. Reset is only
// valid after all candidate pointers have been consumed. Public scans never use
// this storage because callers may retain their immutable candidate pointers.
type Storage[T any] struct {
	chunks [][]T
	next   int
}

func (s *Storage[T]) chunk() []T {
	// A breaker fail-open pass can need a further chunk after the ordinary
	// pass. Overflow remains request-owned and never grows retained storage.
	if s.next >= MaxStorageChunks {
		return make([]T, 0, ChunkSize)
	}
	if s.next == len(s.chunks) {
		s.chunks = append(s.chunks, make([]T, ChunkSize))
	}
	c := s.chunks[s.next]
	s.next++
	return c[:0]
}

// Reset drops every provider/evidence reference in every historical chunk,
// including slots released during a rejected candidate evaluation.
func (s *Storage[T]) Reset() {
	for _, c := range s.chunks {
		clear(c)
	}
	s.next = 0
}
