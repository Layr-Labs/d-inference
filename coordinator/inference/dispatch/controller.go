// Package dispatch owns inference provider selection, queue handoff, speculative
// failover and the first-content commit, using the shared attempt and settlement
// services for request lifecycle operations.
package dispatch

import "sync"

// Controller holds the concurrency and feedback state shared by dispatches.
// Request-specific mutable state stays in an execution created by Run.
type Controller struct {
	deps Dependencies

	hedgeGov           *hedgeGovernor
	routingScanSem     chan struct{}
	routeLatencyMu     sync.Mutex
	routeLatencyEWMAMs float64
}

// Config selects construction-time concurrency controls. Zero values preserve
// the unbounded scan and disabled hedge governor of an unconfigured API server.
type Config struct {
	RoutingConcurrency int
	HedgeGovernor      bool
}

// New binds the current services without taking a snapshot of their settings.
func New(deps Dependencies, cfg Config) *Controller {
	c := &Controller{deps: deps}
	if cfg.HedgeGovernor {
		c.hedgeGov = newHedgeGovernor()
	}
	if cfg.RoutingConcurrency > 0 {
		c.routingScanSem = make(chan struct{}, cfg.RoutingConcurrency)
	}
	return c
}
