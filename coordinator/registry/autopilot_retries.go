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
		if delivery, ok := p.autopilotState.Retry(now); ok {
			retries = append(retries, retry{p, delivery.Command})
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()
	for _, retry := range retries {
		r.sendAutopilotCommand(retry.p, retry.command)
	}
}
