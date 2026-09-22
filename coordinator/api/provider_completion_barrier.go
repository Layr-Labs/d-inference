package api

import "sync"

// Billing completion runs off the socket reader. Snapshot its outstanding
// workers at a drain frame without blocking heartbeats/challenges or waiting on
// workers started after that frame. No request content or identifiers are kept.
type providerCompletionBarrier struct {
	mu      sync.Mutex
	pending map[chan struct{}]struct{}
}

func (b *providerCompletionBarrier) begin() func() {
	done := make(chan struct{})
	b.mu.Lock()
	if b.pending == nil {
		b.pending = make(map[chan struct{}]struct{})
	}
	b.pending[done] = struct{}{}
	b.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			b.mu.Lock()
			delete(b.pending, done)
			close(done)
			b.mu.Unlock()
		})
	}
}

func (b *providerCompletionBarrier) snapshot() []<-chan struct{} {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]<-chan struct{}, 0, len(b.pending))
	for done := range b.pending {
		out = append(out, done)
	}
	return out
}
