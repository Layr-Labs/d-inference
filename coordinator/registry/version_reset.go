package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// SetVersion serializes version observation with provider identity rebinding.
func (p *Provider) SetVersion(version string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.Version = version
	if p.registry != nil {
		p.registry.gates.ObserveVersion(p.gateSession, version)
	}
}

func (r *Registry) IsSupersededDisconnectFlush(sessionID string, statusCode int, causes ...protocol.CoordinatorInferenceErrorCause) bool {
	return r.gates.IsSupersededDisconnectFlush(sessionID, statusCode, causes...)
}
