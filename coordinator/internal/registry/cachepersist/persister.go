package cachepersist

import (
	"log/slog"
	"sync"

	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Persister owns serialized store IO; queue holds its leaf-locked mutations.
type Persister struct {
	store       crs.Store
	logger      *slog.Logger
	fingerprint string
	flushMu     sync.Mutex
	queue       *cachequeue.Queue
}

func New(st crs.Store, logger *slog.Logger, fingerprint string, queue *cachequeue.Queue) *Persister {
	if logger == nil {
		logger = slog.Default()
	}
	return &Persister{store: st, logger: logger, fingerprint: fingerprint, queue: queue}
}

func (p *Persister) Wake() <-chan struct{} {
	if p == nil {
		return nil
	}
	return p.queue.ResetWake
}

func (p *Persister) Ready() bool {
	if p == nil {
		return false
	}
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	return p.queue.Ready
}
