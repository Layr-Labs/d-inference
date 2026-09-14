package warmpool

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// Bindings connects live fleet operations. Tick serializes these callbacks as
// before; no state, queue, snapshot or configuration mutex is held during them.
type Bindings[A any] struct {
	FleetSnapshot    func(time.Time) map[string]FleetModel
	PendingCount     func(time.Time) int
	Reserve          func([]A, time.Time) []A
	Send             func([]A)
	IsDedicatedModel func(string) bool
	Action           func(providerID, modelID string) A
	Logger           func() *slog.Logger
}

// Controller owns the runner, coalesced kicks, plan serialization, pressure and
// last-observation cache. Registry/provider locks remain with the live bindings.
type Controller[A any] struct {
	bindings    Bindings[A]
	config      atomic.Pointer[Config]
	state       *State
	queueMu     queuePressureState
	tickMu      sync.Mutex
	triggerC    chan struct{}
	lastMu      sync.RWMutex
	lastSnaps   []Snapshot[A]
	lastSnapsAt time.Time
}

func NewController[A any](cfg Config, bindings Bindings[A]) *Controller[A] {
	c := &Controller[A]{
		bindings: bindings,
		state:    NewState(),
		queueMu:  queuePressureState{models: make(map[string]QueuePressure)},
		triggerC: make(chan struct{}, 1),
	}
	c.Configure(cfg)
	return c
}

// Configure publishes the same configuration value without taking tickMu:
// callers may already hold a registry lock that a running tick will acquire.
func (c *Controller[A]) Configure(cfg Config) { c.config.Store(&cfg) }
func (c *Controller[A]) configuration() Config {
	if cfg := c.config.Load(); cfg != nil {
		return *cfg
	}
	return Config{}
}
func (c *Controller[A]) Enabled() bool     { return c.configuration().Enabled }
func (c *Controller[A]) ObserveOnly() bool { return c.configuration().ObserveOnly }

func (c *Controller[A]) RequestTrigger() bool {
	select {
	case c.triggerC <- struct{}{}:
		return true
	default:
		return false
	}
}

// PendingTriggers reports queue occupancy without exposing the mutable channel.
func (c *Controller[A]) PendingTriggers() int { return len(c.triggerC) }
func (c *Controller[A]) logger() *slog.Logger {
	if c.bindings.Logger == nil {
		return nil
	}
	return c.bindings.Logger()
}
func (c *Controller[A]) RecordEvent(model string, event Event, now time.Time) {
	c.state.RecordEvent(model, event, now)
}
func (c *Controller[A]) RecordLoad(model string, success bool, duration time.Duration, now time.Time) {
	c.state.RecordLoad(model, success, duration, now)
}
