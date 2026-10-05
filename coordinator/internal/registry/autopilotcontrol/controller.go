package autopilotcontrol

import (
	"slices"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

type Operations[T comparable] interface {
	Tick(time.Time) autopilot.Summary
	Fleet(time.Time) Fleet[T]
	Reserve(Action[T], time.Time) (protocol.ModelAutopilotMessage, bool)
	Stop()
}

type Factory[T comparable] func(*Controller[T]) Operations[T]

type Ports[T comparable] struct {
	Snapshot         func(time.Time) Fleet[T]
	BeginReservation func(time.Time) (Reservation[T], bool)
	Flush            func() bool
	Refresh          func(time.Time)
	Watchdogs        func(time.Time)
	Retry            func(time.Time)
	Paused           func() bool
	Pause            func()
	Propose          func(Action[T], time.Time)
	Deliver          func(Action[T], protocol.ModelAutopilotMessage, time.Time) bool
	Send             func(T, protocol.ModelAutopilotMessage)
	Publish          func(autopilot.Summary, time.Time)
}

type Controller[T comparable] struct {
	config autopilot.Config
	ports  Ports[T]
	tickMu sync.Mutex // never acquired by heartbeat or routing
}

func New[T comparable](cfg autopilot.Config, ports Ports[T]) *Controller[T] {
	return &Controller[T]{config: cfg, ports: ports}
}

func (c *Controller[T]) Fleet(now time.Time) Fleet[T] {
	return c.ports.Snapshot(now)
}

func (c *Controller[T]) Stop() {
	c.ports.Pause()
	c.tickMu.Lock()
	defer c.tickMu.Unlock()
	c.RefreshControlLeases(time.Now())
	c.ports.Flush()
}

func (c *Controller[T]) RefreshControlLeases(now time.Time) { c.ports.Refresh(now) }
func (c *Controller[T]) Watchdogs(now time.Time)            { c.ports.Watchdogs(now) }
func (c *Controller[T]) Retry(now time.Time)                { c.ports.Retry(now) }

func (c *Controller[T]) Tick(now time.Time) autopilot.Summary {
	started := time.Now()
	c.tickMu.Lock()
	defer c.tickMu.Unlock()
	ledgerReady := c.ports.Flush()
	c.RefreshControlLeases(time.Now())
	if !c.config.ObserveOnly {
		c.Watchdogs(now)
		c.Retry(now)
	}
	f := c.Fleet(now)
	summary := autopilot.Summarize(f.Fleet, c.config, now)
	remaining := c.config.MaxConcurrentOperations - summary.Pending - f.LegacyPending
	limit := min(c.config.MaxActionsPerTick, max(0, remaining))
	if c.ports.Paused() || !ledgerReady {
		limit = 0
	}
	for range limit {
		action := Plan(f, c.config, now)
		if action == nil {
			break
		}
		summary.Proposed++
		if c.config.ObserveOnly {
			c.ports.Propose(*action, now)
			// Debit only this pass. Hypothetical capacity never reaches routing.
			for i := range f.Nodes {
				if f.Nodes[i].ID == action.Node.ID {
					f.Nodes[i].Pending = true
					f.Nodes[i].Future = action.Future
					f.Nodes[i].FutureResidents = []string{}
					for _, m := range action.Node.Residents {
						if !slices.Contains(action.Unload, m) {
							f.Nodes[i].FutureResidents = append(f.Nodes[i].FutureResidents, m)
						}
					}
					if action.Load != "" {
						f.Nodes[i].FutureResidents = append(f.Nodes[i].FutureResidents, action.Load)
					}
				}
			}
			continue
		}
		command, ok := c.Reserve(*action, now)
		if !ok {
			break
		}
		if !c.ports.Deliver(*action, command, now) {
			break
		}
		summary.Issued++
		c.ports.Send(action.Session, command)
		f = c.Fleet(now)
	}
	c.ports.Publish(summary, started)
	return summary
}
