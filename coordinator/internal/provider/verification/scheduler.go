package verification

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"log/slog"
	"math/rand/v2"
	"sync"
	"time"
)

const (
	mdmSchedulerDispatchInterval = time.Second
	// mdmSchedulerReservedUrgentWorkers holds back worker capacity that only
	// first/expired SecurityInfo attempts may occupy. A provider in that state
	// has no usable trust grant, so routed client requests are already burning
	// the 120s dispatch-queue deadline; long-running refresh MDA attempts (up
	// to 60s each) must never be able to occupy every worker and starve it.
	// Urgent work may still use general capacity; the reservation only caps
	// refresh/recovery work at Workers-1 when Workers > 1.
	mdmSchedulerReservedUrgentWorkers = 1
	// mdmFirstVerifySpreadMax caps the initial spread for first/expired
	// SecurityInfo work. A provider in this state has no valid trust grant, so
	// a client request routed to it is already burning the 120s dispatch-queue
	// deadline (plus up to 90s of verification wait). The tiny jitter only
	// de-synchronises mass expiry; it must stay well inside that deadline.
	mdmFirstVerifySpreadMax    = 5 * time.Second
	mdmSchedulerCleanupTimeout = 5 * time.Second
	mdmRetryFirstMin           = 2 * time.Minute
	mdmRetryFirstMax           = 4 * time.Minute
	mdmRetrySecondMin          = 6 * time.Minute
	mdmRetrySecondMax          = 12 * time.Minute
	mdmRetrySteadyMin          = 15 * time.Minute
	mdmRetrySteadyMax          = 30 * time.Minute
)

type Timer interface {
	C() <-chan time.Time
	Stop() bool
}

type realMDMSchedulerTimer struct{ *time.Timer }

func (t realMDMSchedulerTimer) C() <-chan time.Time { return t.Timer.C }

type AttemptResult struct {
	Outcome  store.VerificationOutcome
	Granted  bool
	Terminal bool
	UDID     string
}

type Dependencies struct {
	Now              func() time.Time
	NewTimer         func(time.Duration) Timer
	Jitter           func(time.Duration, time.Duration) time.Duration
	Execute          func(context.Context, Binding, store.VerificationTaskKind, string) AttemptResult
	ReuseMDA         func(Binding) bool
	PersistProvider  func(*registry.Provider)
	LegacyMDMAllowed func(*registry.Provider) bool
}

type verificationDuePageStore interface {
	ListDueVerificationJobsPage(
		ctx context.Context,
		now time.Time,
		limit, offset int,
	) ([]store.VerificationJob, error)
}

type Binding struct {
	ProviderID       string
	Provider         *registry.Provider
	Attestation      attestation.VerificationResult
	Generation       uint64
	Context          context.Context
	ChallengeSettled bool
	AllowMDA         bool
	// promoteFirstOrExpired marks that this connection's trust-reuse fast-skip
	// DECLINED, so a refresh-classified SecurityInfo job must settle as
	// first/expired (immediate due) — the submit-time hasFreshRecord
	// classification was optimistic and the provider holds no usable trust
	// grant while client requests burn the 120s dispatch-queue deadline.
	PromoteFirstOrExpired bool
}

type scheduledJob struct {
	Record        store.VerificationJob
	BindingGen    uint64
	CallbackGen   uint64
	CallbackUUID  string
	EnqueuedAt    time.Time
	Running       bool
	AttemptCancel context.CancelFunc
}

type mdmSchedulerWork struct {
	key        string
	job        store.VerificationJob
	binding    Binding
	ctx        context.Context
	cancel     context.CancelFunc
	stopAfter  func() bool
	EnqueuedAt time.Time
}

// Scheduler owns the only MDM/MDA dispatcher and worker pool.
// Durable rows are timing/claim metadata only; every attempt still requires a
// current registration-bound live binding.
type Scheduler struct {
	*Queue
	logger      *slog.Logger
	observation *observation.Owner
	observer    *Observer
	store       store.ProviderStore
	deps        Dependencies
	owner       string

	ctx     context.Context
	cancel  context.CancelFunc
	start   sync.Once
	workers sync.Once
	close   sync.Once
	wg      sync.WaitGroup
	wake    chan struct{}
	work    chan mdmSchedulerWork
}

func New(st store.ProviderStore, logger *slog.Logger, obs *observation.Owner, queue *Queue, deps Dependencies) *Scheduler {
	if deps.Now == nil {
		deps.Now = time.Now
	}
	if deps.NewTimer == nil {
		deps.NewTimer = func(d time.Duration) Timer {
			return realMDMSchedulerTimer{time.NewTimer(d)}
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
	ctx, cancel := context.WithCancel(context.Background())
	observer := NewObserver(obs, deps.Now)
	sch := &Scheduler{
		Queue: queue, logger: logger, observation: obs, observer: observer, store: st, deps: deps,
		owner: uuid.NewString(), ctx: ctx, cancel: cancel,
		wake: make(chan struct{}, 1), work: make(chan mdmSchedulerWork, queue.Configuration().Workers),
	}
	sch.registerMetrics()
	return sch
}

func (s *Scheduler) Start() {
	if s == nil {
		return
	}
	s.start.Do(func() {
		s.wg.Add(1)
		go s.dispatcher()
		s.StartWorkers()
	})
}

// StartWorkers starts the bounded executor pool independently of the dispatch
// driver. Start uses it for the automatic driver; explicit drivers may load and
// dispatch complete batches before allowing the next scheduling turn.
func (s *Scheduler) StartWorkers() {
	s.workers.Do(func() {
		s.wg.Add(s.config.Workers)
		for range s.config.Workers {
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
			if job.AttemptCancel != nil {
				job.AttemptCancel()
			}
		}
		s.mu.Unlock()
		s.Start()
		s.wg.Wait()

		s.mu.Lock()
		claimed := make([]store.VerificationJob, 0, s.config.Workers)
		for _, job := range s.jobs {
			if job.Record.State == store.VerificationStateRunning &&
				job.Record.ClaimOwner == s.owner {
				claimed = append(claimed, job.Record)
			}
		}
		s.mu.Unlock()
		if len(claimed) == 0 {
			return
		}
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		defer cancel()
		now := s.deps.Now().UTC()
		for _, rec := range claimed {
			if err := s.store.ReleaseVerificationJob(
				cleanupCtx, rec.SEPubKey, rec.Kind, s.owner, now,
			); err != nil {
				s.logger.Error(
					"failed to release MDM scheduler claim during shutdown",
					"error", err,
				)
			}
		}
	})
}

func (s *Scheduler) Wake() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func mdmSchedulerCleanupContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), mdmSchedulerCleanupTimeout)
}
