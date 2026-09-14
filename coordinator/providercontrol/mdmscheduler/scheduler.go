package mdmscheduler

import (
	"context"
	rand "math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// Scheduler owns the only MDM/MDA dispatcher and worker pool.
// Durable rows are timing/claim metadata only; every attempt still requires a
// current registration-bound live binding.
type Scheduler struct {
	store Store
	cfg   Config
	deps  Dependencies
	owner string

	ctx    context.Context
	cancel context.CancelFunc
	start  sync.Once
	close  sync.Once
	wg     sync.WaitGroup
	wake   chan struct{}
	work   chan workItem

	mu            sync.Mutex
	jobs          map[string]*scheduledJob
	bindings      map[string]*Binding
	generation    atomic.Uint64
	byUDID        map[string]string
	active        map[store.VerificationTaskKind]int
	activeUrgent  int
	dueScanOffset int
}

func (s *Scheduler) Start() {
	if s == nil {
		return
	}
	s.start.Do(func() {
		s.wg.Add(1 + s.cfg.Workers)
		go s.dispatcher()
		for range s.cfg.Workers {
			go s.worker()
		}
	})
}

func (s *Scheduler) Close() {
	if s == nil {
		return
	}
	s.close.Do(func() {
		s.cancel()
		s.mu.Lock()
		for _, job := range s.jobs {
			if job.attemptCancel != nil {
				job.attemptCancel()
			}
		}
		s.mu.Unlock()
		s.Start()
		s.wg.Wait()

		s.mu.Lock()
		claimed := make([]store.VerificationJob, 0, s.cfg.Workers)
		for _, job := range s.jobs {
			if job.record.State == store.VerificationStateRunning &&
				job.record.ClaimOwner == s.owner {
				claimed = append(claimed, job.record)
			}
		}
		s.mu.Unlock()
		if len(claimed) == 0 {
			return
		}
		cleanupCtx, cancel := cleanupContext()
		defer cancel()
		now := s.deps.Now().UTC()
		for _, rec := range claimed {
			if err := s.store.ReleaseVerificationJob(
				cleanupCtx, rec.SEPubKey, rec.Kind, s.owner, now,
			); err != nil {
				s.deps.Logger().Error(
					"failed to release MDM scheduler claim during shutdown",
					"error", err,
				)
			}
		}
	})
}

func (s *Scheduler) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func cleanupContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), cleanupTimeout)
}

// New creates the single dispatcher and worker pool; Start begins background work.
func New(cfg Config, deps Dependencies) *Scheduler {
	cfg = normalizeConfig(cfg)
	if deps.Now == nil {
		deps.Now = time.Now
	}
	if deps.NewTimer == nil {
		deps.NewTimer = func(d time.Duration) Timer {
			return realTimer{time.NewTimer(d)}
		}
	}
	if deps.Jitter == nil {
		deps.Jitter = func(minimum, maximum time.Duration) time.Duration {
			if maximum <= minimum {
				return minimum
			}
			return minimum + rand.N(maximum-minimum+1)
		}
	}
	if deps.Execute == nil {
		deps.Execute = NewExecutor(deps).Execute
	}
	if deps.ReuseMDA == nil {
		deps.ReuseMDA = func(target Target) bool {
			return deps.Verifier().AttachCachedMDA(target.ProviderID, target.Provider, target.Attestation)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	sch := &Scheduler{
		store: deps.Store, cfg: cfg, deps: deps,
		owner: uuid.NewString(), ctx: ctx, cancel: cancel,
		wake: make(chan struct{}, 1), work: make(chan workItem, cfg.Workers),
		jobs: make(map[string]*scheduledJob), bindings: make(map[string]*Binding),
		byUDID: make(map[string]string), active: make(map[store.VerificationTaskKind]int),
	}
	sch.registerMetrics()
	return sch
}
