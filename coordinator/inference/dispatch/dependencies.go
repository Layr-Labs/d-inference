package dispatch

import (
	"context"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// Store is the existing credit operation used when an unsent queued reservation
// must be returned. Other financial operations use the shared settlement service.
type Store interface {
	Credit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error
}

// Counters preserves the configured metrics sink and its disabled state.
type Counters interface {
	Enabled() bool
	Incr(name string, tags []string)
	Count(name string, value int64, tags []string)
	Histogram(name string, value float64, tags []string)
	Gauge(name string, value float64, tags []string)
}

// Observer publishes dispatch evidence through the existing route, rejection
// and request-outcome funnels. Those funnels retain their terminal claims and
// durable submission ordering.
type Observer interface {
	Route(*store.InferenceRouteRecord)
	PendingOutcome(*registry.PendingRequest, *store.InferenceRouteOutcome)
	RouteOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome)
	Rejection(Rejection)
	RequestOutcome(model string, attribution KVBackendAttribution, class string)
	RequestOutcomeORView(model, class string)
	Event(context.Context, protocol.TelemetrySeverity, string, string, map[string]any)
	ClientGone(model string, promptTokens int, chipFamily, phase, deadlineBucket string)
	CoordinatorExhausted(context.Context, bool)
}

// Dependencies retain the original read points for mutable configuration and
// shared services. The getters return the current bindings on every invocation.
type Dependencies struct {
	Registry               func() *registry.Registry
	Store                  func() Store
	Logger                 func() *slog.Logger
	Metrics                func() *metrics.Registry
	BillingConfigured      func() bool
	Attempts               func() attempt.Service
	Settlement             func() settlement.Service
	Response               func() *response.Writer
	HoldForSettlement      func(*registry.PendingRequest)
	MinDecodeTPS           func() float64
	TTFTHardReject         func() bool
	DisableClientErrorStop func() bool
	Counters               Counters
	Observer               Observer
}
