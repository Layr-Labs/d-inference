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

// The inventory identity is bound only after verified machine continuity. A
// serial, account, endpoint key or connection ID cannot enroll a live machine.
// Caller holds p.mu; controller configuration is immutable.
func (c *modelAutopilotController) liveMachineLocked(p *Provider) bool {
	if c.config.ObserveOnly {
		return false
	}
	account, machine := p.VerifiedMachineIdentityLocked()
	_, selected := c.liveMachines[machine]
	return account != "" && account == p.AccountID && selected
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
	r := c.registry
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.autopilot != c {
		return
	}
	for _, p := range r.providers {
		p.mu.Lock()
		if providerAutopilotConsentedLocked(p) && p.writer != nil {
			enabled := c.config.Enabled && !c.paused.Load() &&
				!p.ModelAutopilot.Paused && !p.PrivateOnly
			expiry := now.Add(3*c.config.Interval + 10*time.Second)
			if !enabled {
				expiry = now
			}
			message := protocol.ModelAutopilotControl{
				Type: protocol.TypeModelAutopilotControl, SessionID: p.ID,
				Revision: p.ModelAutopilot.Revision, Enabled: enabled, ObserveOnly: !c.liveMachineLocked(p), ExpiresAtMS: expiry.UnixMilli(),
			}
			body, err := json.Marshal(message)
			// Enqueue is bounded, never a socket wait. Keep the current session,
			// verified identity and accepted grant atomic under the provider lock;
			// an earlier staged live grant must not overwrite a later demotion.
			if err == nil && p.writer.Enqueue(context.Background(), body) == nil {
				p.autopilotState.AcceptControl(p.ModelAutopilot, message)
			}
		}
		p.mu.Unlock()
	}
}
