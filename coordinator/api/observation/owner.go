// Package observation owns request observations and their independent sinks.
// It does not decide routing, billing, or terminal arbitration.
package observation

import (
	"context"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

type Hooks struct {
	RoutePattern               func(*http.Request) string
	RequireAdminKey            func(http.ResponseWriter, *http.Request) bool
	HasAutopilotDemand         func(context.Context) bool
	BindAutopilotDemandProfile func(*http.Request, *registry.RequestProfile)
	MinProviderVersion         func() string
	EmitExactCacheDDGauges     func()
}

type Dependencies struct {
	Store                store.Store
	Registry             *registry.Registry
	Logger               *slog.Logger
	Hooks                Hooks
	ProfileFallbackGrace time.Duration
}

type Owner struct {
	store                store.Store
	registry             *registry.Registry
	logger               *slog.Logger
	hooks                Hooks
	metrics              *Metrics
	dd                   *datadog.Client
	emitter              *telemetry.Emitter
	profiler             *profiler
	routeTelemetry       *telemetrySink
	requestOutcomes      *requestOutcomeSink
	unknownRequestFrames atomic.Int64
	profileFallbackGrace time.Duration
	queueGauges          queueGaugeState
}

func New(deps Dependencies) *Owner {
	s := &Owner{store: deps.Store, registry: deps.Registry, logger: deps.Logger, hooks: deps.Hooks, metrics: NewMetrics(), profileFallbackGrace: deps.ProfileFallbackGrace}
	if s.profileFallbackGrace == 0 {
		s.profileFallbackGrace = 31 * time.Second
	}
	if s.store != nil {
		s.routeTelemetry = newTelemetrySink(s.logger, defaultTelemetrySinkCapacity, defaultTelemetrySinkWorkers)
	}
	s.profiler = newProfilerFromEnv(s)
	if s.store != nil {
		s.requestOutcomes = newRequestOutcomeSink(s, defaultTelemetrySinkCapacity)
	}
	return s
}

func (s *Owner) Metrics() *Metrics {
	if s == nil {
		return nil
	}
	return s.metrics
}
func (s *Owner) SetDatadog(dd *datadog.Client) { s.dd = dd }
func (s *Owner) Datadog() *datadog.Client {
	if s == nil {
		return nil
	}
	return s.dd
}
func (s *Owner) SetEmitter(e *telemetry.Emitter) { s.emitter = e }
func (s *Owner) Emitter() *telemetry.Emitter {
	if s == nil {
		return nil
	}
	return s.emitter
}
func (s *Owner) AddUnknownRequestFrames(n int64) {
	if s != nil {
		s.unknownRequestFrames.Add(n)
	}
}
func (s *Owner) UnknownRequestFrames() int64 {
	if s == nil {
		return 0
	}
	return s.unknownRequestFrames.Load()
}

// FlushRoutes retains the route sink's bounded drain, separate from the compact
// outcome drain and profile stop that occur later in the server shutdown order.
func (s *Owner) FlushRoutes() {
	if s == nil || s.routeTelemetry == nil {
		return
	}
	if !s.routeTelemetry.closeAndWait(telemetrySinkShutdownFlush) && s.logger != nil {
		s.logger.Warn("routing telemetry sink did not finish flushing before the shutdown deadline", "deadline", telemetrySinkShutdownFlush, "dropped_total", s.routeTelemetry.dropped.Load())
	}
}

func (s *Owner) CloseProfilesAndOutcomes() {
	if s == nil {
		return
	}
	if s.requestOutcomes != nil {
		s.requestOutcomes.close()
	}
	if s.profiler != nil {
		s.profiler.close()
	}
}

func (s *Owner) Close() { s.FlushRoutes(); s.CloseProfilesAndOutcomes() }

func (s *Owner) SubmitTelemetry(name string, fn func()) {
	if s == nil {
		return
	}
	if s.routeTelemetry != nil {
		s.routeTelemetry.submit(fn)
		return
	}
	saferun.Go(s.logger, name, fn)
}

func (s *Owner) ddIncr(name string, tags []string) {
	if s != nil && s.dd != nil {
		s.dd.Incr(name, tags)
	}
}
func (s *Owner) ddCount(name string, count int64, tags []string) {
	if s != nil && s.dd != nil {
		s.dd.Count(name, count, tags)
	}
}
func (s *Owner) ddGauge(name string, value float64, tags []string) {
	if s != nil && s.dd != nil {
		s.dd.Gauge(name, value, tags)
	}
}
