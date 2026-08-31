package api

import (
	"context"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	mdmSchedulerDispatchInterval = time.Second
	mdmSchedulerCleanupTimeout   = 5 * time.Second
	mdmRetryFirstMin             = 2 * time.Minute
	mdmRetryFirstMax             = 4 * time.Minute
	mdmRetrySecondMin            = 6 * time.Minute
	mdmRetrySecondMax            = 12 * time.Minute
	mdmRetrySteadyMin            = 15 * time.Minute
	mdmRetrySteadyMax            = 30 * time.Minute
)

type mdmSchedulerTimer interface {
	C() <-chan time.Time
	Stop() bool
}

type realMDMSchedulerTimer struct{ *time.Timer }

func (t realMDMSchedulerTimer) C() <-chan time.Time { return t.Timer.C }

type mdmSchedulerAttemptResult struct {
	outcome  store.VerificationOutcome
	granted  bool
	terminal bool
	udid     string
}

type mdmSchedulerDeps struct {
	now      func() time.Time
	newTimer func(time.Duration) mdmSchedulerTimer
	jitter   func(time.Duration, time.Duration) time.Duration
	execute  func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult
	reuseMDA func(mdmLiveBinding) bool
}

type verificationDuePageStore interface {
	ListDueVerificationJobsPage(
		ctx context.Context,
		now time.Time,
		limit, offset int,
	) ([]store.VerificationJob, error)
}

type mdmLiveBinding struct {
	providerID       string
	provider         *registry.Provider
	attestation      attestation.VerificationResult
	generation       uint64
	ctx              context.Context
	challengeSettled bool
	allowMDA         bool
}

type mdmScheduledJob struct {
	record        store.VerificationJob
	bindingGen    uint64
	callbackGen   uint64
	callbackUUID  string
	enqueuedAt    time.Time
	running       bool
	attemptCancel context.CancelFunc
}

type mdmSchedulerWork struct {
	key        string
	job        store.VerificationJob
	binding    mdmLiveBinding
	ctx        context.Context
	cancel     context.CancelFunc
	stopAfter  func() bool
	enqueuedAt time.Time
}

// mdmVerificationScheduler owns the only MDM/MDA dispatcher and worker pool.
// Durable rows are timing/claim metadata only; every attempt still requires a
// current registration-bound live binding.
type mdmVerificationScheduler struct {
	server *Server
	store  store.ProviderStore
	cfg    MDMSchedulerConfig
	deps   mdmSchedulerDeps
	owner  string

	ctx    context.Context
	cancel context.CancelFunc
	start  sync.Once
	close  sync.Once
	wg     sync.WaitGroup
	wake   chan struct{}
	work   chan mdmSchedulerWork

	mu            sync.Mutex
	jobs          map[string]*mdmScheduledJob
	bindings      map[string]*mdmLiveBinding
	generation    atomic.Uint64
	byUDID        map[string]string
	active        map[store.VerificationTaskKind]int
	dueScanOffset int
}

func newMDMVerificationScheduler(s *Server, cfg MDMSchedulerConfig, deps mdmSchedulerDeps) *mdmVerificationScheduler {
	cfg = normalizeMDMSchedulerConfig(cfg)
	if deps.now == nil {
		deps.now = time.Now
	}
	if deps.newTimer == nil {
		deps.newTimer = func(d time.Duration) mdmSchedulerTimer {
			return realMDMSchedulerTimer{time.NewTimer(d)}
		}
	}
	if deps.jitter == nil {
		deps.jitter = func(minimum, maximum time.Duration) time.Duration {
			if maximum <= minimum {
				return minimum
			}
			return minimum + rand.N(maximum-minimum+1)
		}
	}
	if deps.execute == nil {
		deps.execute = s.executeScheduledVerification
	}
	if deps.reuseMDA == nil {
		deps.reuseMDA = func(binding mdmLiveBinding) bool {
			return s.attachCachedMDAProof(binding.providerID, binding.provider, binding.attestation)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	sch := &mdmVerificationScheduler{
		server: s, store: s.store, cfg: cfg, deps: deps,
		owner: uuid.NewString(), ctx: ctx, cancel: cancel,
		wake: make(chan struct{}, 1), work: make(chan mdmSchedulerWork, cfg.Workers),
		jobs: make(map[string]*mdmScheduledJob), bindings: make(map[string]*mdmLiveBinding),
		byUDID: make(map[string]string), active: make(map[store.VerificationTaskKind]int),
	}
	sch.registerMetrics()
	return sch
}

func verificationSchedulerKey(seKey string, kind store.VerificationTaskKind) string {
	return seKey + "\x00" + string(kind)
}

func (s *mdmVerificationScheduler) Start() {
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

func (s *mdmVerificationScheduler) Close() {
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
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		defer cancel()
		now := s.deps.now().UTC()
		for _, rec := range claimed {
			if err := s.store.ReleaseVerificationJob(
				cleanupCtx, rec.SEPubKey, rec.Kind, s.owner, now,
			); err != nil {
				s.server.logger.Error(
					"failed to release MDM scheduler claim during shutdown",
					"error", err,
				)
			}
		}
	})
}

func (s *mdmVerificationScheduler) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func mdmSchedulerCleanupContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), mdmSchedulerCleanupTimeout)
}
