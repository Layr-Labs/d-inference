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
	fleet "github.com/eigeninference/d-inference/coordinator/internal/observation/fleet"
	outcomes "github.com/eigeninference/d-inference/coordinator/internal/observation/outcomes"
	profile "github.com/eigeninference/d-inference/coordinator/internal/observation/profile"
	routes "github.com/eigeninference/d-inference/coordinator/internal/observation/routes"
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
	Profiles             *profile.Profiler
	QueueGauges          *fleet.QueueGauges
	ThroughputDetector   *fleet.ThroughputDetector
	RouteSinkFactory     func(*slog.Logger) *routes.Sink
}

type Owner struct {
	store                store.Store
	registry             *registry.Registry
	logger               *slog.Logger
	hooks                Hooks
	metrics              *Metrics
	dd                   *datadog.Client
	emitter              *telemetry.Emitter
	profiler             *profile.Profiler
	routeTelemetry       *routes.Sink
	requestOutcomes      *outcomes.Sink
	unknownRequestFrames atomic.Int64
	profileFallbackGrace time.Duration
	queueGauges          *fleet.QueueGauges
	throughputDetector   *fleet.ThroughputDetector
}

func New(deps Dependencies) *Owner {
	s := &Owner{store: deps.Store, registry: deps.Registry, logger: deps.Logger, hooks: deps.Hooks, metrics: NewMetrics(), profileFallbackGrace: deps.ProfileFallbackGrace}
	s.queueGauges = deps.QueueGauges
	if s.queueGauges == nil {
		s.queueGauges = &fleet.QueueGauges{}
	}
	s.throughputDetector = deps.ThroughputDetector
	if s.throughputDetector == nil {
		s.throughputDetector = fleet.NewThroughputDetector(fleet.DetectorDependencies{Registry: s.registry, Logger: s.logger, Incr: s.Incr, Counter: func(model, chip string) {
			if s.metrics != nil {
				s.metrics.IncCounter("routing.throughput_anomaly", MetricLabel{Name: "model", Value: model}, MetricLabel{Name: "chip_family", Value: chip})
			}
		}})
	}
	if s.profileFallbackGrace == 0 {
		s.profileFallbackGrace = 31 * time.Second
	}
	if s.store != nil {
		if deps.RouteSinkFactory != nil {
			s.routeTelemetry = deps.RouteSinkFactory(s.logger)
		} else {
			s.routeTelemetry = routes.New(s.logger, routes.DefaultCapacity, routes.DefaultWorkers)
		}
	}
	s.profiler = deps.Profiles
	if s.profiler == nil {
		s.profiler = profile.NewFromEnv(profile.Dependencies{Store: s.store, Logger: s.logger, Incr: s.ddIncr, Count: s.ddCount})
	}
	if s.store != nil {
		s.requestOutcomes = outcomes.New(outcomes.Dependencies{Store: s.store, Logger: s.logger, Incr: s.ddIncr, Count: s.ddCount}, routes.DefaultCapacity)
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
	if !s.routeTelemetry.CloseAndWait(routes.ShutdownFlush) && s.logger != nil {
		s.logger.Warn("routing telemetry sink did not finish flushing before the shutdown deadline", "deadline", routes.ShutdownFlush, "dropped_total", s.routeTelemetry.Stats().Dropped)
	}
}

func (s *Owner) CloseProfilesAndOutcomes() {
	if s == nil {
		return
	}
	if s.requestOutcomes != nil {
		s.requestOutcomes.Close()
	}
	if s.profiler != nil {
		s.profiler.Close()
	}
}

func (s *Owner) Close() { s.FlushRoutes(); s.CloseProfilesAndOutcomes() }

func (s *Owner) SubmitTelemetry(name string, fn func()) {
	if s == nil {
		return
	}
	if s.routeTelemetry != nil {
		s.routeTelemetry.Submit(fn)
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
