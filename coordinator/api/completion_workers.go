package api

import (
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

const (
	defaultCompletionWorkers  = 16
	defaultCompletionCapacity = 256
)

type completionWorkerPool struct {
	logger  *slog.Logger
	queue   chan func()
	workers int

	mu      sync.Mutex
	started bool
	closed  bool
	wg      sync.WaitGroup
	active  atomic.Int64
}

func newCompletionWorkerPool(logger *slog.Logger, capacity, workers int) *completionWorkerPool {
	if capacity <= 0 {
		capacity = defaultCompletionCapacity
	}
	if workers <= 0 {
		workers = defaultCompletionWorkers
	}
	return &completionWorkerPool{
		logger: logger, queue: make(chan func(), capacity), workers: workers,
	}
}

// submit applies lossless bounded backpressure. Financial completion work is
// never dropped and no goroutine is created per terminal.
func (p *completionWorkerPool) submit(task func()) bool {
	if p == nil || task == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return false
	}
	if !p.started {
		p.startLocked()
	}
	p.queue <- task
	return true
}

func (p *completionWorkerPool) startLocked() {
	p.started = true
	p.wg.Add(p.workers)
	for range p.workers {
		go p.run()
	}
}

func (p *completionWorkerPool) run() {
	defer p.wg.Done()
	for task := range p.queue {
		p.active.Add(1)
		func() {
			defer p.active.Add(-1)
			defer saferun.Recover(p.logger, "completion_worker")
			task()
		}()
	}
}

func (p *completionWorkerPool) close() {
	if p == nil {
		return
	}
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	if p.started {
		close(p.queue)
	}
	p.mu.Unlock()
	p.wg.Wait()
}

func (p *completionWorkerPool) depth() int {
	if p == nil {
		return 0
	}
	return len(p.queue)
}

func (p *completionWorkerPool) capacity() int {
	if p == nil {
		return 0
	}
	return cap(p.queue)
}

func (p *completionWorkerPool) activeCount() int64 {
	if p == nil {
		return 0
	}
	return p.active.Load()
}
