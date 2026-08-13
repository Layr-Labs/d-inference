package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	lmStudioModelPrefix = "lmstudio/"
	maxLMStudioModels   = 64
)

// ReplaceLMStudioModels replaces only the dynamic LM Studio portion of a
// provider's inventory. It is intentionally limited to linked providers and a
// reserved namespace so these off-catalog models can only use owner self-route.
func (r *Registry) ReplaceLMStudioModels(providerID string, models []protocol.ModelInfo) (added, removed []string) {
	r.mu.RLock()
	p := r.providers[providerID]
	r.mu.RUnlock()
	if p == nil {
		return nil, nil
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.AccountID == "" {
		return nil, nil
	}

	next := make([]protocol.ModelInfo, 0, len(p.Models)+min(len(models), maxLMStudioModels))
	previous := make(map[string]struct{})
	for _, model := range p.Models {
		if strings.HasPrefix(model.ID, lmStudioModelPrefix) {
			previous[model.ID] = struct{}{}
			continue
		}
		next = append(next, model)
	}

	seen := make(map[string]struct{})
	for _, model := range models {
		if len(seen) >= maxLMStudioModels {
			break
		}
		if !strings.HasPrefix(model.ID, lmStudioModelPrefix) || model.ID == lmStudioModelPrefix {
			continue
		}
		if _, duplicate := seen[model.ID]; duplicate {
			continue
		}
		seen[model.ID] = struct{}{}
		next = append(next, model)
		if _, existed := previous[model.ID]; !existed {
			added = append(added, model.ID)
		}
	}
	for id := range previous {
		if _, remains := seen[id]; !remains {
			removed = append(removed, id)
		}
	}
	p.Models = next
	return added, removed
}
