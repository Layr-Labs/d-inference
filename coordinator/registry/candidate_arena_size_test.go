package registry

import (
	"testing"
	"unsafe"
)

// The 32-slot candidate chunk is allocated as one pointer-bearing object, so
// the runtime prepends an 8-byte malloc header (Go 1.22+) and rounds the
// total up to a size class. Today routingCandidate is 760 B: 32 × 760 + 8 =
// 24,328 B, inside the 24,576 B class. Growing the struct by a single word
// (768 B) makes 24,584 B, which spills into the 27,264 B class — 2.7 KB of
// waste per chunk on every fleet scan with no change in allocs/op. Exactly
// that happened when an extra bool was tried on routingCandidate during the
// in-gap pending work (+24 KB/op on BenchmarkReserveProviderEx_350x2), so
// per-candidate facts must be derived from the snapshot, not stored.
const (
	candidateArenaSizeClassBytes = 24_576
	mallocHeaderBytes            = 8
)

func TestCandidateArenaChunkStaysInSizeClass(t *testing.T) {
	size := unsafe.Sizeof(routingCandidate{})
	alloc := size*candidateArenaChunk + mallocHeaderBytes
	t.Logf("routingCandidate = %d B; chunk allocation = %d B (size class %d)", size, alloc, candidateArenaSizeClassBytes)
	if alloc > candidateArenaSizeClassBytes {
		t.Fatalf("candidate arena chunk allocation %d B exceeds the %d B size class: routingCandidate grew to %d B — derive the new fact from the snapshot instead", alloc, candidateArenaSizeClassBytes, size)
	}
}
