// Package dispatch owns the reserve, prepare, encrypt and authorized handoff of
// one provider attempt. The inference owner retains terminal settlement authority.
package dispatch

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backoff"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/responselimit"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/scangate"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	ChunkBufferSize      = 256
	ModelTooLarge        = "model too large for any available provider"
	TTFTTooSlow          = "all available providers exceed the TTFT target"
	RoutingScanSaturated = "routing scan capacity saturated \u2014 coordinator busy"
	ClientGoneBeforeScan = "client disconnected before provider selection"
)

// Scope carries routing constraints, not mutable request lifecycle state.
type Scope struct {
	SelfRouteOnly  bool
	PreferOwner    bool
	OwnerAccountID string
}

type Exclusions interface {
	IDs() []string
	Exclude(string)
}

type Reserver func(*registry.PendingRequest, []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan)
type RouteRecorder func(*registry.Provider, *registry.PendingRequest, registry.RoutingDecision)

type Dependencies struct {
	Registry     *registry.Registry
	Store        store.Store
	Observation  *observation.Owner
	Logger       *slog.Logger
	Reservations *reservations.Controller
	Cancellation *cancellation.Controller
	Gate         *scangate.Gate
	Backoff      *backoff.Policy
	Calibration  *estimate.ContextCalibration
	RecordPolicy func(*registry.AttemptProfile, Scope, bool)
	CloseAttempt func(*registry.AttemptProfile, string, int)
}

type Config struct {
	BillingEnabled bool
	HardTTFTReject bool
	MinDecodeTPS   float64
	ResponseLimits responselimit.Limits
}

type Dispatcher struct {
	registry       *registry.Registry
	store          store.Store
	observation    *observation.Owner
	logger         *slog.Logger
	reservations   *reservations.Controller
	cancels        *cancellation.Controller
	gate           *scangate.Gate
	backoff        *backoff.Policy
	calibration    *estimate.ContextCalibration
	recordPolicy   func(*registry.AttemptProfile, Scope, bool)
	closeAttempt   func(*registry.AttemptProfile, string, int)
	billingEnabled bool
	ttftHardReject bool
	minDecodeTPS   float64
	responseLimits responselimit.Limits
}

func New(d Dependencies, cfg Config) *Dispatcher {
	return &Dispatcher{registry: d.Registry, store: d.Store, observation: d.Observation, logger: d.Logger,
		reservations: d.Reservations, cancels: d.Cancellation, gate: d.Gate, backoff: d.Backoff,
		calibration: d.Calibration, recordPolicy: d.RecordPolicy, closeAttempt: d.CloseAttempt,
		billingEnabled: cfg.BillingEnabled, ttftHardReject: cfg.HardTTFTReject, minDecodeTPS: cfg.MinDecodeTPS,
		responseLimits: cfg.ResponseLimits}
}

func (s *Dispatcher) hardTTFTGate(requiresVision bool) bool {
	return s.ttftHardReject && !requiresVision
}

func (s *Dispatcher) ScanReserver(model string) Reserver {
	return func(pr *registry.PendingRequest, excluded []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
		return s.registry.ReserveProviderWithPlan(model, pr, excluded...)
	}
}

func (s *Dispatcher) releaseUnsentDispatch(provider *registry.Provider, pr *registry.PendingRequest) {
	if provider == nil || pr == nil {
		return
	}
	firstcontent.ReleaseUnsent(s.registry, provider, pr)
}
