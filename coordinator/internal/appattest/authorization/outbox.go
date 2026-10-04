package authorization

import (
	"context"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Outbox coalesces bounded asynchronous policy notifications. A provider stays
// pending until its notification finishes, not merely until it is dequeued.
type Outbox struct {
	mu      sync.Mutex
	queue   chan *registry.Provider
	pending map[*registry.Provider]bool
}

func NewOutbox(capacity int) *Outbox {
	return &Outbox{queue: make(chan *registry.Provider, capacity), pending: make(map[*registry.Provider]bool)}
}

func (o *Outbox) Offer(p *registry.Provider) {
	if p == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.pending[p] {
		return
	}
	select {
	case o.queue <- p:
		o.pending[p] = true
	default:
	}
}

func (o *Outbox) Next(ctx context.Context) (*registry.Provider, bool) {
	select {
	case <-ctx.Done():
		return nil, false
	case p := <-o.queue:
		return p, true
	}
}

func (o *Outbox) Complete(p *registry.Provider) {
	o.mu.Lock()
	delete(o.pending, p)
	o.mu.Unlock()
}

func (o *Outbox) Pending() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return len(o.pending)
}
