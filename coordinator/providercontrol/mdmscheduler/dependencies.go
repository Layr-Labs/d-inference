package mdmscheduler

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/verification"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

type Timer interface {
	C() <-chan time.Time
	Stop() bool
}

type realTimer struct{ *time.Timer }

func (t realTimer) C() <-chan time.Time { return t.Timer.C }

// Target copies the registration evidence used by a single scheduled attempt.
// The Provider pointer is the same live connection observed by verification.
type Target struct {
	ProviderID  string
	Provider    *registry.Provider
	Attestation attestation.VerificationResult
}

// AttemptResult is the executor's observation, settled durably by the worker.
type AttemptResult struct {
	Outcome  store.VerificationOutcome
	Granted  bool
	Terminal bool
	UDID     string
}

// Store contains only durable queue and claim operations. Optional paged scans
// are discovered through store.As, preserving decorated backend capabilities.
type Store interface {
	UpsertVerificationJob(context.Context, store.VerificationJob) (store.VerificationJob, error)
	GetVerificationJob(context.Context, string, store.VerificationTaskKind) (*store.VerificationJob, error)
	ListDueVerificationJobs(context.Context, time.Time, int) ([]store.VerificationJob, error)
	ClaimVerificationJob(context.Context, string, store.VerificationTaskKind, string, time.Time, time.Time) (store.VerificationJob, bool, error)
	ReleaseVerificationJob(context.Context, string, store.VerificationTaskKind, string, time.Time) error
	CompleteVerificationJob(context.Context, string, store.VerificationTaskKind, string, store.VerificationOutcome, time.Time) error
	RescheduleVerificationJob(context.Context, string, store.VerificationTaskKind, string, store.VerificationPriority, int, time.Duration, time.Time, store.VerificationOutcome, time.Time) error
}

// Registry persists only the live provider whose binding passed revalidation.
type Registry interface{ PersistProvider(*registry.Provider) }

// Verifier checks evidence; it does not own scheduler admission or settlement.
type Verifier interface {
	VerifySecurityInfo(context.Context, string, *registry.Provider, attestation.VerificationResult) verification.Outcome
	VerifyMDA(context.Context, string, *registry.Provider, attestation.VerificationResult, string)
	AttachCachedMDA(string, *registry.Provider, attestation.VerificationResult) bool
}

// Dependencies binds durable claims at construction and reads current resources
// at each existing use. Optional clock and executor hooks control scheduling;
// nil hooks use the real clock, jitter and verification executor.
type Dependencies struct {
	Store     Store
	Registry  func() Registry
	Logger    func() *slog.Logger
	Metrics   func() *metrics.Registry
	Counter   func(string, []string)
	Gauge     func(string, float64, []string)
	Histogram func(string, float64, []string)
	Verifier  func() Verifier
	Now       func() time.Time
	NewTimer  func(time.Duration) Timer
	Jitter    func(time.Duration, time.Duration) time.Duration
	Execute   func(context.Context, Target, store.VerificationTaskKind, string) AttemptResult
	ReuseMDA  func(Target) bool
}
