package registry

import "sync"

// ResponseBudget bounds both payload and per-chunk retention. Limits are fixed
// before publication; the mutex makes accounting safe for concurrent callers.
// Rejection is sticky and does not retain the rejected payload.
type ResponseBudget struct {
	mu                  sync.Mutex
	maxBytes, maxChunks int
	bytes, chunks       int
	rejected            bool
}

func NewResponseBudget(maxBytes, maxChunks int) *ResponseBudget {
	return &ResponseBudget{maxBytes: maxBytes, maxChunks: maxChunks}
}

// Accept accounts one chunk of size bytes and reports whether the caller may
// retain it. A chunk that exactly reaches a limit is accepted; an empty chunk
// still uses a chunk slot. A nil budget accepts everything: streaming attempts
// carry none.
func (b *ResponseBudget) Accept(size int) bool {
	if b == nil {
		return true
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.rejected || size < 0 || size > b.maxBytes-b.bytes || b.chunks >= b.maxChunks {
		b.rejected = true
		return false
	}
	b.bytes += size
	b.chunks++
	return true
}
