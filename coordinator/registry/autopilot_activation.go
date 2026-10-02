package registry

import (
	"context"
	"encoding/json"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func providerAutopilotConsentedLocked(p *Provider) bool {
	s := p.ModelAutopilot
	return s != nil && s.Protocol == protocol.ModelAutopilotProtocol && s.Enabled &&
		s.CachedOnly && s.Revision != "" && len(s.Revision) <= 64 &&
		len(s.SelectedModels) > 0 && len(s.SelectedModels) <= 256
}

func providerAutopilotAllowsLocked(p *Provider, model string) bool {
	return providerAutopilotConsentedLocked(p) && slices.Contains(p.ModelAutopilot.SelectedModels, model)
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
		if providerAutopilotConsentedLocked(d.p) && d.p.ModelAutopilot.Revision == d.message.Revision {
			d.p.autopilotControlUntil = time.UnixMilli(d.message.ExpiresAtMS)
			d.p.autopilotControlRevision = d.message.Revision
			d.p.autopilotControlObserveOnly = d.message.ObserveOnly
		}
		d.p.mu.Unlock()
	}
}
