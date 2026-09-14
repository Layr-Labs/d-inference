package providerframe

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// chunkOverflowGrace is how long Chunk will block the provider read loop
// waiting for a full ChunkCh to free one slot before failing the request. It
// trades a bounded head-of-line stall for this provider's OTHER streams
// against killing a healthy consumer that is merely catching up after a TCP
// burst (WS stall recovery, engine batch flush, slow mobile links). A stuck
// consumer costs one grace window and is then failed; a consumer that drains
// at least one chunk per window keeps its stream alive.
const chunkOverflowGrace = 250 * time.Millisecond

// sendChunkWithGrace blocks up to chunkOverflowGrace for a slot on pr.ChunkCh
// and reports whether the chunk was delivered. The recover guard mirrors
// registry.Disconnect's own channel idiom: Disconnect can close ChunkCh from
// another goroutine while we are blocked in the send, and a closed channel
// here simply means the request is already torn down (delivered=false; the
// caller's terminal path degrades to a no-op warn).
func sendChunkWithGrace(pr *registry.PendingRequest, chunk registry.ProviderChunk) (delivered bool) {
	defer func() {
		if recover() != nil {
			delivered = false
		}
	}()
	wait := time.NewTimer(chunkOverflowGrace)
	defer wait.Stop()
	select {
	case pr.ChunkCh <- chunk:
		return true
	case <-wait.C:
		return false
	}
}
