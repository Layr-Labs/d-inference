package response

import (
	"net/http"
)

// maxCoalescedBatchBytes bounds the bytes one coalesced batch may hold before
// it is written and flushed. maxCoalescedChunks alone bounds only the count:
// the provider WebSocket read limit is 10 MiB (handleProviderWS), so one
// decrypted chunk can approach 7.5 MiB, and a 32-chunk batch could reach
// ~240 MiB — or ~1.9 GiB on the whole-channel drain (chunkBufferSize = 256)
// ahead of a provider error — held in a single buffer per stream. Healthy
// deltas are a few hundred bytes (32 of them ≈ 10 KiB), so the byte cap never
// fires on a normal stream; it exists so a faulty or hostile provider cannot
// turn concurrent streams into coordinator memory exhaustion. Only the chat
// relay buffers frames itself (chatStreamRelay.buf); the emitter relays write
// each event straight to the ResponseWriter and defer only the Flush.
const maxCoalescedBatchBytes = 256 << 10

// deferredFlusher lets per-event emitters keep calling Flush while the relay
// loop decides when bytes actually reach the wire: Flush only marks the writer
// dirty, and flushNow performs one real flush if anything was marked. Writes
// themselves still go straight to the http.ResponseWriter (net/http buffers
// them until the flush).
type DeferredFlusher struct {
	inner http.Flusher
	dirty bool
}

func NewDeferredFlusher(inner http.Flusher) *DeferredFlusher {
	return &DeferredFlusher{inner: inner}
}

// Flush implements http.Flusher by recording that a flush is owed.
func (f *DeferredFlusher) Flush() { f.dirty = true }

// flushNow performs the owed flush, if any.
func (f *DeferredFlusher) FlushNow() {
	if f.dirty {
		f.dirty = false
		f.inner.Flush()
	}
}
