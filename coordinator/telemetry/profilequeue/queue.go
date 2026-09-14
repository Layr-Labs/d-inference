package profilequeue

import (
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

const DefaultCapacity = 4096

// Writer is the one persistence operation used by the profile worker.
type Writer interface {
	RecordRequestProfiles([]*store.RequestProfileRecord) error
}

// Hooks connect the queue to record construction and telemetry. Store resolves
// the active writer at flush time, preserving the server's live store lookup.
// Build runs only on the worker. Incr and Count may be nil when no metrics are
// installed; Logger may be nil. Callers provide Build and Store.
type Hooks struct {
	Logger *slog.Logger
	Build  func(*registry.RequestProfile, *registry.AttemptProfile) *store.RequestProfileRecord
	Store  func() Writer
	Incr   func(string, []string)
	Count  func(string, int64, []string)
}

// job retains the finalized attempt until its record can be built on the
// worker. The caller owns the request/attempt lifecycle and finalization.
type job struct {
	rp *registry.RequestProfile
	ap *registry.AttemptProfile
}

// Sink owns one bounded queue and one worker. Submit never waits for a build
// or store call. Close signals the worker without waiting: it flushes a batch
// it already holds, but does not promise to drain all buffered jobs.
type Sink struct {
	hooks     Hooks
	ch        chan job
	done      chan struct{}
	dropped   atomic.Int64
	written   atomic.Int64
	closeOnce sync.Once
}

func New(hooks Hooks, capacity int) *Sink {
	if capacity <= 0 {
		capacity = DefaultCapacity
	}
	p := &Sink{hooks: hooks, ch: make(chan job, capacity), done: make(chan struct{})}
	go p.worker()
	return p
}

// Submit enqueues a finalized attempt without blocking; full buffers drop
// and count the new job. Nil inputs do not enter the queue or count as drops.
func (p *Sink) Submit(rp *registry.RequestProfile, ap *registry.AttemptProfile) bool {
	if p == nil || rp == nil || ap == nil {
		return false
	}
	select {
	case p.ch <- job{rp: rp, ap: ap}:
		return true
	default:
		n := p.dropped.Add(1)
		if telemetry.CrossesPowerOfTen(n-1, n) && p.hooks.Logger != nil {
			p.hooks.Logger.Warn("profile sink dropping records (buffer full) — inference is unaffected",
				"dropped_total", n, "capacity", cap(p.ch))
		}
		if p.hooks.Incr != nil {
			p.hooks.Incr("telemetry.sink_dropped", []string{"sink:profile"})
		}
		return false
	}
}

func (p *Sink) Close() {
	if p == nil {
		return
	}
	p.closeOnce.Do(func() { close(p.done) })
}
