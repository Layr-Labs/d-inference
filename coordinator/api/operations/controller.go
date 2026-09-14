// Package operations serves read-only operator telemetry and record exports.
// Collection, persistence and fleet synchronization stay with their owners.
package operations

import (
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
	"github.com/eigeninference/d-inference/coordinator/telemetry/outcomequeue"
)

// OutcomeCounters exposes process observations without queue mutation or lifecycle.
type OutcomeCounters interface{ Stats() outcomequeue.Stats }

// Dependencies resolve the current observations and authorization settings at
// request time. Outcomes returns a real nil when collection is unavailable.
type Dependencies struct {
	Store              func() Store
	Metrics            func() metrics.Snapshot
	Utilization        func() registry.NetworkUtilization
	Outcomes           func() OutcomeCounters
	AuthorizeTelemetry func(http.ResponseWriter, *http.Request) bool
	AuthorizeMetrics   func(http.ResponseWriter, *http.Request) bool
	Logger             func() *slog.Logger
}

// Controller owns the operator read/export policy and its narrow dependencies.
// It owns no collection workers and never writes to the observation store.
type Controller struct {
	store              func() Store
	metrics            func() metrics.Snapshot
	utilization        func() registry.NetworkUtilization
	outcomes           func() OutcomeCounters
	authorizeTelemetry func(http.ResponseWriter, *http.Request) bool
	authorizeMetrics   func(http.ResponseWriter, *http.Request) bool
	logger             func() *slog.Logger
}

func New(d Dependencies) *Controller {
	return &Controller{
		store:              d.Store,
		metrics:            d.Metrics,
		utilization:        d.Utilization,
		outcomes:           d.Outcomes,
		authorizeTelemetry: d.AuthorizeTelemetry,
		authorizeMetrics:   d.AuthorizeMetrics,
		logger:             d.Logger,
	}
}
