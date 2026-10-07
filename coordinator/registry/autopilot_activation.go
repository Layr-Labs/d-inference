package registry

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func providerAutopilotConsentedLocked(p *Provider) bool {
	return autopilotstate.Consented(p.ModelAutopilot)
}

func providerAutopilotAllowsLocked(p *Provider, model string) bool {
	return autopilotstate.Allows(p.ModelAutopilot, model)
}

// Pausing stops reservations immediately; accepted operations retain their
// owner, watchdog and heartbeat reconciliation until the final state is known.
func (r *Registry) SetAutopilotPaused(paused bool) bool {
	r.mu.RLock()
	c := r.autopilot
	r.mu.RUnlock()
	if c == nil {
		return false
	}
	c.paused.Store(paused)
	return true
}

func (c *modelAutopilotController) refreshControlLeases(now time.Time) {
	type delivery struct {
		p       *Provider
		message protocol.ModelAutopilotControl
	}
	var pending []delivery
	r := c.registry
	r.mu.RLock()
	for _, p := range r.providers {
		p.mu.Lock()
		if providerAutopilotConsentedLocked(p) {
			enabled := c.config.Enabled && !c.paused.Load() &&
				!p.ModelAutopilot.Paused && !p.PrivateOnly
			expiry := now.Add(3*c.config.Interval + 10*time.Second)
			if !enabled {
				expiry = now
			}
			pending = append(pending, delivery{p, protocol.ModelAutopilotControl{
				Type: protocol.TypeModelAutopilotControl, SessionID: p.ID,
				Revision: p.ModelAutopilot.Revision, Enabled: enabled, ObserveOnly: c.config.ObserveOnly, ExpiresAtMS: expiry.UnixMilli(),
			}})
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()
	for _, d := range pending {
		body, err := json.Marshal(d.message)
		if err != nil {
			continue
		}
		// Renewals are best-effort control state, acknowledged by a matching
		// provider heartbeat. The existing bounded priority lane and per-socket
		// watchdog isolate slow peers without serial wire waits in this tick.
		// Full queues retain the previous lease; expiry restores ordinary policy.
		if err := d.p.EnqueueText(context.Background(), body); err != nil {
			continue
		}
		d.p.mu.Lock()
		d.p.autopilotState.AcceptControl(d.p.ModelAutopilot, d.message)
		d.p.mu.Unlock()
	}
}
