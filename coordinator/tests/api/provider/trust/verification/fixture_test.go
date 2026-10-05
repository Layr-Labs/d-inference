package verification_test

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type MDMSchedulerConfig = verification.Config
type mdmSchedulerDeps = verification.Dependencies
type mdmSchedulerTimer = verification.Timer
type mdmLiveBinding = verification.Binding
type mdmSchedulerAttemptResult = verification.AttemptResult

var verificationSchedulerKey = verification.Key
var normalizeMDMSchedulerConfig = verification.NormalizeConfig
var ReadMDMSchedulerConfig = verification.ReadConfig
var IsUrgent = verification.IsUrgent

const (
	defaultMDMVerificationWorkers = 12
	defaultMDMVerificationQueue   = 4096
	mdmFirstVerifySpreadMax       = 5 * time.Second
	mdmSchedulerBusyRetryDelay    = 250 * time.Millisecond
	mdmRetryFirstMin              = 2 * time.Minute
	mdmRetryFirstMax              = 4 * time.Minute
	mdmRetrySecondMin             = 6 * time.Minute
	mdmRetrySecondMax             = 12 * time.Minute
	mdmRetrySteadyMin             = 15 * time.Minute
	mdmRetrySteadyMax             = 30 * time.Minute
)

type realMDMSchedulerTimer struct{ *time.Timer }

func (t realMDMSchedulerTimer) C() <-chan time.Time { return t.Timer.C }

type schedulerFixture struct {
	registry    *registry.Registry
	observation *observation.Owner
}

// The harness selects either the same automatic driver as trust.Owner or
// explicit scheduling turns. Both run the component's real workers and storage.
type mdmVerificationScheduler struct {
	*verification.Scheduler
	store  store.ProviderStore
	cfg    MDMSchedulerConfig
	deps   mdmSchedulerDeps
	manual bool
}

func (s *mdmVerificationScheduler) Submit(ctx context.Context, id string, p *registry.Provider, priority store.VerificationPriority) uint64 {
	if !s.manual {
		return (&verification.Service{Scheduler: s.Scheduler}).Submit(ctx, id, p, priority)
	}
	return s.Scheduler.Submit(ctx, id, p, priority)
}

func (s *mdmVerificationScheduler) NextDispatchDelay() time.Duration {
	return s.Queue.NextDispatchDelay(s.deps.Now())
}

func (s *mdmVerificationScheduler) RetryDelay(stage int) time.Duration {
	return verification.RetryDelay(stage, s.deps.Jitter)
}

type verificationDuePageStore interface {
	ListDueVerificationJobsPage(context.Context, time.Time, int, int) ([]store.VerificationJob, error)
}
