package ingress

import (
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Fixture inputs are actual collaborators, bound through the same getters as
// the API. HTTP authentication, encryption and durable evidence stay in API
// integration tests; these fixtures exercise private ingress operations.
type testServices struct {
	registry                 *registry.Registry
	store                    Store
	logger                   *slog.Logger
	mediaResolver            *mediafetch.Resolver
	firstContentDeadlineBase time.Duration
	consumerTokenLimiter     *ratelimit.TokenLimiter
	serviceTokenLimiter      *ratelimit.TokenLimiter
	keyTokenLimiter          *ratelimit.KeyTokenLimiter
	outputAdmissionEstimator *ratelimit.OutputAdmissionEstimator
}

func newTestController(services testServices) *Controller {
	c := New(Dependencies{
		Registry:                 func() *registry.Registry { return services.registry },
		Store:                    func() Store { return services.store },
		Logger:                   func() *slog.Logger { return services.logger },
		MediaResolver:            func() *mediafetch.Resolver { return services.mediaResolver },
		FirstContentDeadlineBase: func() time.Duration { return services.firstContentDeadlineBase },
		ConsumerTokens:           func() *ratelimit.TokenLimiter { return services.consumerTokenLimiter },
		ServiceTokens:            func() *ratelimit.TokenLimiter { return services.serviceTokenLimiter },
		KeyTokens:                func() *ratelimit.KeyTokenLimiter { return services.keyTokenLimiter },
		OutputAdmissionEstimator: func() *ratelimit.OutputAdmissionEstimator { return services.outputAdmissionEstimator },
		SealedRequest:            func(r *http.Request) bool { return r.Context().Value(fixtureSealedKey{}) != nil },
	})
	if services.registry != nil {
		d := dispatch.New(dispatch.Dependencies{
			Registry: c.deps.Registry, Logger: c.deps.Logger,
			MinDecodeTPS:   func() float64 { return 0 },
			TTFTHardReject: func() bool { return false },
			Counters:       fixtureCounters{},
		}, dispatch.Config{RoutingConcurrency: dispatch.DefaultRoutingConcurrency(), HedgeGovernor: true})
		c.deps.Dispatch = func() *dispatch.Controller { return d }
	}
	return c
}

func testController(t testing.TB) (*Controller, *store.MemoryStore) {
	t.Helper()
	logger := quietLogger()
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	return newTestController(testServices{
		registry: registry.New(logger), store: st, logger: logger,
		firstContentDeadlineBase: 5 * time.Second,
	}), st
}

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

type fixtureSealedKey struct{}
type fixtureCounters struct{ noMetrics }

func (fixtureCounters) Enabled() bool                   { return false }
func (fixtureCounters) Gauge(string, float64, []string) {}

type testConfig struct{ FirstContentDeadlineBase time.Duration }

func testControllerWithConfig(t testing.TB, cfg testConfig) (*Controller, *store.MemoryStore) {
	c, st := testController(t)
	if cfg.FirstContentDeadlineBase > 0 {
		c.deps.FirstContentDeadlineBase = func() time.Duration { return cfg.FirstContentDeadlineBase }
	}
	return c, st
}
func newTestAdmissionController(t testing.TB) *Controller { c, _ := testController(t); return c }
