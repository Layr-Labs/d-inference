package attempt

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type InflightAbandonDependencies struct {
	Registry    *registry.Registry
	Observation *observation.Owner
	Routes      *outcome.Recorder
	Cancel      func(*registry.Provider, *registry.PendingRequest) bool
}

type AbandonResult struct {
	Claimed            bool
	Failure            retry.AttemptFailure
	ExcludedProviderID string
	Provider           *registry.Provider
	Pending            *registry.PendingRequest
}

type InflightAbandon struct {
	deps   InflightAbandonDependencies
	config TimeoutConfig
}

func NewInflightAbandon(deps InflightAbandonDependencies, config TimeoutConfig) *InflightAbandon {
	return &InflightAbandon{deps: deps, config: config}
}

// Run retires an on-wire attempt before the exhausted ladder refunds it. An
// on-time ingress claim retains ownership; otherwise the local clock, not any
// earlier provider error, owns the terminal reason.
func (a *InflightAbandon) Run(deadline time.Duration) AbandonResult {
	c, d := a.config, a.deps
	result := AbandonResult{
		Claimed:  true,
		Failure:  retry.CoordinatorFailure("timeout waiting for first response", http.StatusGatewayTimeout),
		Provider: c.Provider,
		Pending:  c.Pending,
	}
	if c.Provider == nil || c.Pending == nil {
		return result
	}
	if !d.Cancel(c.Provider, c.Pending) {
		return AbandonResult{Provider: c.Provider, Pending: c.Pending}
	}
	result.ExcludedProviderID = c.Provider.ID
	d.Registry.RecordWarmPoolTTFTMiss(c.Model, deadline)
	outcome.CaptureAttempt(c.Provider, c.Pending, c.RequestID, c.Attempt).Record(d.Routes, c.Model,
		func(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
			return retry.ErrorRouteOutcome(pr, "timeout", "first_chunk_timeout", result.Failure.Message)
		})
	if d.Observation.Metrics() != nil {
		d.Observation.Metrics().IncCounter("inference_dispatches_total", observation.MetricLabel{Name: "result", Value: "timeout"})
	}
	d.Observation.Incr("inference.dispatches", []string{"status:timeout"})
	result.Provider, result.Pending = nil, nil
	return result
}
