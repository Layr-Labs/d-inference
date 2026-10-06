package registry

import "time"

// ModelLoadPlanning separates cold-demand planning, atomic reservations and
// command delivery. Implementations retain the registry's actual session owner.
type ModelLoadPlanning interface {
	Plan([]string, time.Time) []ModelLoadAction
	Reserve([]ModelLoadAction, time.Time) []ModelLoadAction
	Send([]ModelLoadAction)
	Expire(time.Time)
}

type ModelLoadPlanner struct{ registry *Registry }

func (p *ModelLoadPlanner) Plan(models []string, now time.Time) []ModelLoadAction {
	preparation := p.Prepare()
	defer preparation.Close()

	selectedProviders := make(map[string]struct{})
	actions := make([]ModelLoadAction, 0, len(models))
	for _, model := range models {
		if p.registry.hasWarmProviderLocked(model, now) {
			continue
		}

		providerID := preparation.bestProvider(model, now, selectedProviders)
		if providerID == "" {
			continue
		}
		selectedProviders[providerID] = struct{}{}
		actions = append(actions, ModelLoadAction{ProviderID: providerID, ModelID: model})
	}
	return actions
}

func (p *ModelLoadPlanner) Reserve(actions []ModelLoadAction, now time.Time) []ModelLoadAction {
	return p.registry.reservePendingModelLoads(actions, now)
}

func (p *ModelLoadPlanner) Send(actions []ModelLoadAction) {
	p.registry.sendModelLoadActions(actions)
}

func (p *ModelLoadPlanner) Expire(now time.Time) { p.registry.expirePendingModelLoads(now) }
