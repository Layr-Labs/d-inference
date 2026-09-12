package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Retry the exact same command, never a new destructive generation. If it was
// lost, the provider rejects its expired acceptance deadline and publishes a
// terminal snapshot; if active/completed, it returns the idempotent status.
// This recovers lost sends/ACKs without inferring completion from TTL expiry.
func (r *Registry) retryAutopilotCommands(now time.Time) {
	type retry struct {
		p       *Provider
		command protocol.ModelAutopilotMessage
	}
	var retries []retry
	r.mu.RLock()
	for _, p := range r.providers {
		p.mu.Lock()
		pending := p.autopilotPending
		if pending != nil && pending.Attempts < 3 && now.Sub(pending.LastSentAt) >= 30*time.Second {
			pending.Attempts++
			pending.LastSentAt = now
			retries = append(retries, retry{p, pending.Command})
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()
	for _, retry := range retries {
		r.sendAutopilotCommand(retry.p, retry.command)
	}
}
