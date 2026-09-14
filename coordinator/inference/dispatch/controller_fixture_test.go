package dispatch

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// These owner fixtures exercise dispatch with real registry and financial
// services. The observer records dispatch's route publications directly; API
// terminal arbitration, metrics and authenticated handlers keep their API tests.
func newTestController(t *testing.T) *Controller {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	return newConfiguredController(registry.New(logger), store.NewMemory(store.Config{}), logger)
}

func newConfiguredController(reg *registry.Registry, st store.Store, logger *slog.Logger) *Controller {
	counters := fixtureCounters{}
	observer := fixtureObserver{store: st}
	accounting := settlement.New(settlement.Dependencies{
		Store: func() settlement.Store { return st }, Ledger: payments.NewLedger(st),
		Providers: func() settlement.Providers { return reg }, Referral: func() settlement.Referral { return nil },
		Metrics: counters, Logger: logger, ServiceHolds: settlement.NewServiceHolds(st, false),
	})
	attempts := attempt.New(attempt.Dependencies{
		Registry: func() *registry.Registry { return reg }, Store: func() attempt.Store { return st },
		Reservations: func() attempt.Reservations { return accounting }, Logger: func() *slog.Logger { return logger },
		Metrics: counters, Tracker: attempt.NewTracker(), UnknownFrame: func(string, *registry.Provider) {},
	})
	writer := response.New(response.Dependencies{
		Reservation: accounting, Feedback: attempts, Outcomes: fixtureResponseOutcomes{}, Metrics: counters, Errors: observer,
	})
	m := metrics.New()
	return New(Dependencies{
		Registry: func() *registry.Registry { return reg }, Store: func() Store { return st },
		Logger: func() *slog.Logger { return logger }, Metrics: func() *metrics.Registry { return m },
		BillingConfigured: func() bool { return false }, Attempts: func() attempt.Service { return attempts },
		Settlement: func() settlement.Service { return accounting }, Response: func() *response.Writer { return writer },
		HoldForSettlement: func(*registry.PendingRequest) {}, MinDecodeTPS: func() float64 { return 0 },
		TTFTHardReject: func() bool { return false }, DisableClientErrorStop: func() bool { return false },
		Counters: counters, Observer: observer,
	}, Config{RoutingConcurrency: DefaultRoutingConcurrency(), HedgeGovernor: true})
}

func testControllerStore(c *Controller) store.Store { return c.deps.Store().(store.Store) }

type fixtureCounters struct{}

func (fixtureCounters) Enabled() bool                       { return false }
func (fixtureCounters) Incr(string, []string)               {}
func (fixtureCounters) Count(string, int64, []string)       {}
func (fixtureCounters) Histogram(string, float64, []string) {}
func (fixtureCounters) Gauge(string, float64, []string)     {}

type fixtureObserver struct{ store store.Store }

func (o fixtureObserver) Route(record *store.InferenceRouteRecord) {
	_ = o.store.RecordInferenceRoute(record)
}
func (o fixtureObserver) PendingOutcome(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	attempt.PublishPendingOutcome(pr, outcome, o)
}
func (fixtureObserver) CacheTerminal(*registry.PendingRequest) {}
func (o fixtureObserver) RouteOutcome(id string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	_ = o.store.UpdateInferenceRouteOutcome(id, attempt, outcome)
}
func (fixtureObserver) Rejection(Rejection)                                 {}
func (fixtureObserver) RequestOutcome(string, KVBackendAttribution, string) {}
func (fixtureObserver) RequestOutcomeORView(string, string)                 {}
func (fixtureObserver) Event(context.Context, protocol.TelemetrySeverity, string, string, map[string]any) {
}
func (fixtureObserver) ClientGone(string, int, string, string, string) {}
func (fixtureObserver) CoordinatorExhausted(context.Context, bool)     {}
func (fixtureObserver) WriteProviderError(http.ResponseWriter, protocol.InferenceErrorMessage) {
	panic("unexpected API error-policy invocation in dispatch fixture")
}

type fixtureResponseOutcomes struct{}

func (fixtureResponseOutcomes) ProviderError(*registry.PendingRequest, protocol.InferenceErrorMessage, bool) {
}
func (fixtureResponseOutcomes) Incomplete(*registry.PendingRequest, bool)      {}
func (fixtureResponseOutcomes) Timeout(*registry.PendingRequest, bool, string) {}
func (fixtureResponseOutcomes) ClientGone(*registry.PendingRequest)            {}
