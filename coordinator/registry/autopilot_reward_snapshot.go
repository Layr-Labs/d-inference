package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// AutopilotRewardConsentSnapshot reads only the last accepted registration or
// heartbeat. Control readiness, pauses, leases and rollout modes are not saved
// consent. Unsupported or malformed declarations fail closed, including older
// providers that report enabled without the separate consent_enabled field.
// supported distinguishes a valid opt-out from missing consent history.
func (p *Provider) AutopilotRewardConsentSnapshot() (optedIn, supported bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	state := p.ModelAutopilot
	if state == nil || state.Protocol != protocol.ModelAutopilotProtocol || state.ConsentEnabled == nil {
		return false, false
	}
	if !*state.ConsentEnabled {
		return false, true
	}
	if !state.CachedOnly || state.Revision == "" || len(state.Revision) > 64 ||
		len(state.SelectedModels) == 0 || len(state.SelectedModels) > 256 {
		return false, false
	}
	for _, id := range state.SelectedModels {
		if id == "" || len(id) > 256 {
			return false, false
		}
	}
	return true, true
}
