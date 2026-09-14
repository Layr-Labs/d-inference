package api

import (
	"context"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

type selfRoutePolicy = dispatch.RoutePolicy
type rejectionInfo = dispatch.Rejection

// inferenceDispatch binds one controller to the server's current services.
// NewServer installs the configured concurrency controls; a directly constructed
// server retains the original nil semaphore and nil hedge governor behavior.
func (s *Server) inferenceDispatch() *dispatch.Controller {
	if s == nil {
		return nil
	}
	s.initializeInferenceDispatch(dispatch.Config{})
	return s.dispatchController
}

func (s *Server) initializeInferenceDispatch(cfg dispatch.Config) {
	s.dispatchOnce.Do(func() {
		s.dispatchController = dispatch.New(dispatch.Dependencies{
			Registry:               func() *registry.Registry { return s.registry },
			Store:                  func() dispatch.Store { return s.store },
			Logger:                 func() *slog.Logger { return s.logger },
			Metrics:                func() *metrics.Registry { return s.metrics },
			BillingConfigured:      func() bool { return s.billing != nil },
			Attempts:               s.inferenceAttempts,
			Settlement:             s.inferenceSettlement,
			Response:               s.responseWriter,
			HoldForSettlement:      s.holdForSettlement,
			MinDecodeTPS:           func() float64 { return s.minDecodeTPS },
			TTFTHardReject:         func() bool { return s.ttftHardReject },
			DisableClientErrorStop: func() bool { return s.disableClientErrorStop },
			Counters:               inferenceMetrics{server: s},
			Observer:               dispatchObserver{server: s},
		}, cfg)
	})
}

// DefaultRoutingConcurrency reports the default scan limit for startup logging.
func DefaultRoutingConcurrency() int { return dispatch.DefaultRoutingConcurrency() }

// SetRoutingConcurrency configures scan admission before serving starts.
func (s *Server) SetRoutingConcurrency(n int) {
	s.inferenceDispatch().SetRoutingConcurrency(n)
}

type dispatchObserver struct{ server *Server }

func (o dispatchObserver) Route(record *store.InferenceRouteRecord) {
	o.server.submitRouteRecord(record)
}
func (o dispatchObserver) PendingOutcome(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	o.server.updateInferenceRouteOutcomeForPending(pr, outcome)
}
func (o dispatchObserver) RouteOutcome(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	o.server.updateInferenceRouteOutcomeWithModel(requestID, attempt, model, outcome)
}
func (o dispatchObserver) Rejection(info dispatch.Rejection) { o.server.recordRejection(info) }
func (o dispatchObserver) RequestOutcome(model string, attribution dispatch.KVBackendAttribution, class string) {
	o.server.recordRequestOutcome(model, attribution, class)
}
func (o dispatchObserver) RequestOutcomeORView(model, class string) {
	o.server.recordRequestOutcomeORView(model, class)
}
func (o dispatchObserver) Event(ctx context.Context, severity protocol.TelemetrySeverity, requestID, message string, fields map[string]any) {
	o.server.emitRequest(ctx, severity, requestID, message, fields)
}
func (o dispatchObserver) ClientGone(model string, promptTokens int, chipFamily, phase, deadlineBucket string) {
	o.server.emitClientGoneBucketed(model, promptTokens, chipFamily, phase, deadlineBucket)
}
func (o dispatchObserver) CoordinatorExhausted(ctx context.Context, exhausted bool) {
	if o := requestOutcomeFromContext(ctx); o != nil {
		o.mu.Lock()
		o.record.CoordinatorExhausted = exhausted
		o.mu.Unlock()
	}
}
