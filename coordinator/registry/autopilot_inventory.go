package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func providerOrdinaryModelAllowedLocked(p *Provider, model string) bool {
	return p.autopilotState.OrdinaryAllowed(p.ModelAutopilot, p.ID, model, time.Now)
}

func (r *Registry) providerPassesAutopilotGatesLocked(p *Provider, model protocol.ModelInfo, traits RequestTraits, now time.Time) bool {
	return (&ProviderEligibility{registry: r}).autopilotGatesLocked(p, model, traits, now)
}

// A selected model's declared alias successor is an ordinary artifact update,
// not a grant to load unrelated cached models. Live-only candidates do not
// become permanent selection roots by being resident under a lease.
func providerSelectedModelLocked(p *Provider, id string) bool {
	return p.autopilotState.Selected(p.Models, id)
}

func (r *Registry) providerCanAcquireDesiredModelLocked(p *Provider, desired, previous string) bool {
	return (&ProviderEligibility{registry: r}).desiredLocked(p, desired, previous)
}

// ServingModelsLocked copies the effective serving advertisement, excluding
// observation-only metadata. The caller must hold p.Mu() for the snapshot.
// UI and stored serving history must share the routing boundary. Integrity
// verification retains the full inventory: an expired lease can leave an
// unroutable model resident while accepted work and cleanup finish.
func (p *Provider) ServingModelsLocked() []protocol.ModelInfo {
	models := make([]protocol.ModelInfo, 0, len(p.Models))
	for _, model := range p.Models {
		if providerOrdinaryModelAllowedLocked(p, model.ID) {
			models = append(models, model)
		}
	}
	return models
}

// Persist the ordinary operator selection, not a transient live control lease.
func (p *Provider) selectedModelsLocked() []protocol.ModelInfo {
	models := make([]protocol.ModelInfo, 0, len(p.Models))
	for _, model := range p.Models {
		if !p.autopilotState.ObserverOnly(model.ID) {
			models = append(models, model)
		}
	}
	return models
}
