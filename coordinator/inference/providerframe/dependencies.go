package providerframe

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Registry applies the same provider effects after each frame's ownership gate.
type Registry interface {
	MarkUntrusted(string)
	MarkDraining(string) bool
	RecordCapacityAcceptOutcome(string, string, bool) bool
	RecordJobSuccess(string, time.Duration)
	RecordJobFailure(string)
	ClearDispatchLoadCooldown(string, string)
	RecordDispatchLoadFailure(string, string) bool
	SetProviderIdle(string)
}

type Metrics interface {
	Incr(string, []string)
	Count(string, int64, []string)
	Histogram(string, float64, []string)
}

// Outcomes preserves the shared publication funnel and its terminal arbitration.
type Outcomes interface {
	RouteOutcome(string, int, string, *store.InferenceRouteOutcome)
	PendingOutcome(*registry.PendingRequest, *store.InferenceRouteOutcome)
}

type Telemetry struct {
	UnknownFrame   func(string, *registry.Provider)
	ClientGone     func(string, int, string, string)
	PartialSuccess func(string, string)
	BackendLatency func(string, dispatch.KVBackendAttribution, float64, float64)
}

// CacheTelemetry shares the API emitter with consumer-side outcome publication.
type CacheTelemetry struct {
	Usage      func(*registry.PendingRequest, protocol.UsageInfo, bool, bool)
	ExactUsage func(string, string, int, int, float64)
	Terminal   func(*registry.PendingRequest, protocol.UsageInfo, bool, bool) bool
	TTFT       func(*registry.PendingRequest, protocol.UsageInfo, bool, float64)
}

// Dependencies reads current resources at the same operation boundaries. The
// service never copies the registry, cancellation tracker, ledger or hold map.
type Dependencies struct {
	Registry           func() Registry
	Logger             func() *slog.Logger
	Attempts           func() attempt.Service
	Settlement         func() settlement.Service
	ClaimSettlement    func(string) *registry.PendingRequest
	RetainProfile      func(*registry.AttemptProfile, []byte)
	ReconcileOutput    func(*registry.PendingRequest, int)
	BackendAttribution func(*registry.Provider, string) dispatch.KVBackendAttribution
	Metrics            Metrics
	Outcomes           Outcomes
	Telemetry          Telemetry
	Cache              CacheTelemetry
}
