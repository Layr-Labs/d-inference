package api

// Streaming-relay coalescing primitives shared by the chat, Responses and
// generic-endpoint relays. When a relay wakes on one provider chunk, chunks
// that are ALREADY queued behind it are folded into the same write + Flush
// instead of costing one syscall each. The drain never waits for more chunks,
// so it adds no latency: a lone chunk is still flushed immediately.

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// maxCoalescedChunks bounds how many provider chunks one relay wake-up folds
// into a single flush (the chunk that woke the relay plus up to
// maxCoalescedChunks-1 already-queued ones). ChunkCh is buffered at 256; the
// bound keeps a badly backed-up stream from starving the error/timeout/context
// arms of the select for more than a handful of chunks.
const maxCoalescedChunks = 32

// drainQueuedChunks non-blockingly pulls up to budget chunks that are already
// queued in ch, handing each to fn in arrival order. It returns closed=true when
// it observed the channel closed instead of a chunk; fn is not called for the
// close, and the caller runs its normal end-of-stream handling only AFTER
// flushing what was drained (so a close never delays already-received chunks).
func drainQueuedChunks(ch <-chan registry.ProviderChunk, budget int, fn func(registry.ProviderChunk)) (closed bool) {
	for i := 0; i < budget; i++ {
		select {
		case c, ok := <-ch:
			if !ok {
				return true
			}
			fn(c)
		default:
			return false
		}
	}
	return false
}

// deferredFlusher lets per-event emitters keep calling Flush while the relay
// loop decides when bytes actually reach the wire: Flush only marks the writer
// dirty, and flushNow performs one real flush if anything was marked. Writes
// themselves still go straight to the http.ResponseWriter (net/http buffers
// them until the flush).
type deferredFlusher struct {
	inner http.Flusher
	dirty bool
}

func newDeferredFlusher(inner http.Flusher) *deferredFlusher {
	return &deferredFlusher{inner: inner}
}

// Flush implements http.Flusher by recording that a flush is owed.
func (f *deferredFlusher) Flush() { f.dirty = true }

// flushNow performs the owed flush, if any.
func (f *deferredFlusher) flushNow() {
	if f.dirty {
		f.dirty = false
		f.inner.Flush()
	}
}

// resetIdleTimer re-arms the relay's idle timeout after a chunk arrived. Every
// chunk is a liveness signal, including ones the relay holds rather than
// forwards, so the caller resets once per chunk (drained chunks included).
func resetIdleTimer(timer *time.Timer, d time.Duration) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
	timer.Reset(d)
}
