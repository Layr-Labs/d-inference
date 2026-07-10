package api

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// completionWorkers bounds handleComplete / settlement side-effect fan-out.
// Unbounded saferun.Go per inference_complete previously created unbounded
// goroutines under completion storms (M0.5).
type completionWorkers struct {
	sem      chan struct{}
	inflight atomic.Int64
	wg       sync.WaitGroup
	logger   *slog.Logger
}

const defaultCompletionWorkers = 32

func newCompletionWorkers(n int, logger *slog.Logger) *completionWorkers {
	if n <= 0 {
		n = defaultCompletionWorkers
	}
	return &completionWorkers{
		sem:    make(chan struct{}, n),
		logger: logger,
	}
}

// Submit runs fn on a bounded worker. If the pool is saturated it still runs
// (blocking until a slot frees) so money/settlement work is never dropped.
func (w *completionWorkers) Submit(name string, fn func()) {
	if w == nil {
		saferun.Go(nil, name, fn)
		return
	}
	w.wg.Add(1)
	w.inflight.Add(1)
	go func() {
		defer w.wg.Done()
		defer w.inflight.Add(-1)
		w.sem <- struct{}{}
		defer func() { <-w.sem }()
		defer saferun.Recover(w.logger, name)
		fn()
	}()
}

func (w *completionWorkers) Inflight() int64 {
	if w == nil {
		return 0
	}
	return w.inflight.Load()
}

func (w *completionWorkers) Wait(ctx context.Context) error {
	if w == nil {
		return nil
	}
	done := make(chan struct{})
	go func() {
		w.wg.Wait()
		close(done)
	}()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-done:
		return nil
	}
}
