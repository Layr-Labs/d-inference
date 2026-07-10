package api

import (
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const settlementRetryAttempts = 3

var errCompletionStopping = errors.New("completion processing stopping")

const (
	defaultCompletionWorkers  = 16
	defaultCompletionCapacity = 256
)

type completionWorkerPool struct {
	logger  *slog.Logger
	queue   chan func()
	workers int

	mu       sync.Mutex
	started  bool
	closed   bool
	wg       sync.WaitGroup
	active   atomic.Int64
	stopping chan struct{}
	stopOnce sync.Once
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
		stopping: make(chan struct{}),
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
	select {
	case <-p.stopping:
		return false
	default:
	}
	if !p.started {
		p.startLocked()
	}
	p.queue <- task
	return true
}

func (p *completionWorkerPool) stop() {
	if p != nil {
		p.stopOnce.Do(func() { close(p.stopping) })
	}
}

func (p *completionWorkerPool) isStopping() bool {
	if p == nil {
		return false
	}
	select {
	case <-p.stopping:
		return true
	default:
		return false
	}
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
	p.stop()
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

func (s *Server) settleInferenceWithRetry(settlement *store.InferenceSettlement) (store.InferenceSettlementDisposition, error) {
	for attempt := 0; ; attempt++ {
		if s.completions != nil && s.completions.isStopping() {
			return "", errCompletionStopping
		}
		disposition, err := s.store.SettleInference(settlement)
		if err == nil {
			return disposition, nil
		}
		if store.IsPermanentFinancialError(err) {
			return s.recordSettlementReviewWithRetry(settlement, err)
		}
		delay := time.Duration(min(attempt+1, 100)) * 50 * time.Millisecond
		time.Sleep(delay)
	}
}

func (s *Server) recordSettlementReviewWithRetry(
	settlement *store.InferenceSettlement,
	settlementErr error,
) (store.InferenceSettlementDisposition, error) {
	reason := settlementErr.Error()
	if len(reason) > 1024 {
		reason = reason[:1024]
	}
	for attempt := 0; ; attempt++ {
		if s.completions != nil && s.completions.isStopping() {
			return "", errCompletionStopping
		}
		disposition, err := s.store.RecordInferenceSettlementReview(settlement, reason)
		if err == nil {
			return disposition, nil
		}
		if store.IsPermanentFinancialError(err) {
			if s.logger != nil {
				s.logger.Error("failed to update durable settlement review",
					"reservation_id", settlement.ReservationID,
					"error", err,
				)
			}
			return "", err
		}
		delay := time.Duration(min(attempt+1, 100)) * 50 * time.Millisecond
		time.Sleep(delay)
	}
}
