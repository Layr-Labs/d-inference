package challenge

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// Registry owns provider identity, reputation, model policy and routing state.
// The challenge owner supplies verified observations to those existing operations.
type Registry interface {
	GetProvider(string) *registry.Provider
	CatalogWeightHash(string) string
	IsAliasLineageBuild(string) bool
	MarkUntrusted(string)
	MarkUntrustedTransient(string)
	RecordChallengeFailure(string, bool) int
	RecordChallengeSuccess(string) bool
	UpdateModelWeightHashes(string, map[string]string)
	ReconcileAttestedRuntimeCapabilities(string) error
	DrainQueuedRequestsForProviderWithReason(*registry.Provider, string)
}

// Scheduler settles or promotes an already-submitted durable verification job.
// A periodic challenge does not submit another MDM command.
type Scheduler interface {
	ChallengeSettled(*registry.Provider, bool)
	PromoteFailedFastSkip(*registry.Provider)
}

type Counters interface {
	IncCounter(string, ...metrics.Label)
}

// Dependencies retain the existing live reads at each operation boundary.
// Optional owner getters must return a true nil interface when absent.
type Dependencies struct {
	Registry                func() Registry
	Logger                  func() *slog.Logger
	Counters                func() Counters
	Scheduler               func() Scheduler
	Skip                    func() bool
	Interval                func() time.Duration
	BinaryHashPolicy        func() (bool, map[string]bool)
	EnforceBinaryHash       func() bool
	NormalizeHash           func(string, string) (string, error)
	ApplyRuntime            func(*registry.Provider, *protocol.AttestationResponseMessage) (bool, bool, []protocol.RuntimeMismatch)
	ApplyMinimumVersion     func(*registry.Provider) (string, bool)
	MinimumVersion          func() string
	DeriveReleaseTransition func(*registry.Provider, *protocol.AttestationResponseMessage, bool) (trustreuse.ReleaseTransition, registry.ApplicationEvidence, bool)
	TryReuse                func(string, *registry.Provider, *protocol.AttestationResponseMessage, bool, ...trustreuse.ReleaseTransition) bool
	AttachMDA               func(string, *registry.Provider, attestation.VerificationResult) bool
	SendStatus              func(*registry.Provider, registry.TrustLevel, string, string)
	Incr                    func(string, []string)
	Emit                    func(context.Context, protocol.TelemetrySeverity, protocol.TelemetryKind, string, map[string]any)
	CodeMetric              func(string)
	EvidenceOutcome         func(string)
}

// Expected contains only the coordinator-generated values for one issued
// challenge. Session obtains it from its private tracker, never from the reply.
type Expected struct{ Nonce, Timestamp string }

// Verifier applies the established ordered challenge checks and transitions.
// It holds no nonce map; each connection creates its own Session.
type Verifier struct{ deps Dependencies }

func New(deps Dependencies) *Verifier { return &Verifier{deps: deps} }
