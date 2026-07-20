package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

const ToolConstraintProtocolV1 = 1

func toolConstraintModelSet(
	advertised []string,
	models []protocol.ModelInfo,
) map[string]struct{} {
	known := make(map[string]struct{}, len(models))
	for _, model := range models {
		if model.ID != "" {
			known[model.ID] = struct{}{}
		}
	}
	result := make(map[string]struct{}, len(advertised))
	for _, model := range advertised {
		if _, exists := known[model]; exists {
			result[model] = struct{}{}
		}
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

func providerSupportsToolConstraintLocked(p *Provider, model string) bool {
	if p.ToolConstraintProtocol != ToolConstraintProtocolV1 {
		return false
	}
	_, ok := p.ToolConstraintModels[model]
	return ok
}
