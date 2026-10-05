package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

// Vision checks the advertised vision build and its catalog integrity gates.
// Owner routing may admit off-catalog builds, but not mismatched catalog hashes.
func (e *ProviderEligibility) Vision(id, model string, allowOffCatalog bool) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.visionLocked(p, model, allowOffCatalog)
}

func (e *ProviderEligibility) visionLocked(p *Provider, model string, allowOffCatalog bool) bool {
	r := e.registry
	for _, m := range p.Models {
		if m.ID != model || !m.IsVision {
			continue
		}
		if allowOffCatalog {
			if !r.modelServableForOwnerLocked(p, m) {
				continue
			}
		} else if !r.providerModelAllowedByCatalogLocked(p, m) {
			continue
		}
		if model == modelpolicy.Qwen3VL30BA3BInstructModelID &&
			strings.EqualFold(strings.TrimSpace(p.Hardware.ChipFamily), "M5") {
			// This concrete VLM produces incorrect visual inference on M5.
			return false
		}
		return true
	}
	return false
}
