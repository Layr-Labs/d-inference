package testbed

import (
	"fmt"
	"maps"
	"slices"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// providerCapabilityMismatch checks original registration evidence, before the
// testbed grants trust. The caller holds p.Mu; this function never mutates p.
func providerCapabilityMismatch(p *registry.Provider, required []string) string {
	for _, capability := range required {
		if !slices.Contains(p.ReportedRuntimeCapabilities, capability) {
			return fmt.Sprintf("provider %s reported chip_family=%q and capabilities=%v; missing %q",
				p.ID, p.Hardware.ChipFamily, p.ReportedRuntimeCapabilities, capability)
		}
		if capability == registry.ProviderCapabilityAppleM5 && p.Hardware.ChipFamily != "M5" {
			return fmt.Sprintf("provider %s reported chip_family=%q, want M5", p.ID, p.Hardware.ChipFamily)
		}
	}
	metallibHash := p.TemplateHashes["mlx_metallib"]
	if metallibHash == "" {
		return fmt.Sprintf("provider %s did not bind mlx_metallib in its registration", p.ID)
	}
	verified := p.AttestationResult
	if verified == nil || !verified.Valid {
		return fmt.Sprintf("provider %s has no valid registration-verified attestation claims", p.ID)
	}
	if verified.ChipFamily != p.Hardware.ChipFamily {
		return fmt.Sprintf("provider %s signed chip_family=%q but reported %q",
			p.ID, verified.ChipFamily, p.Hardware.ChipFamily)
	}
	if !maps.Equal(capabilitySet(verified.RuntimeCapabilities), capabilitySet(p.ReportedRuntimeCapabilities)) {
		return fmt.Sprintf("provider %s signed capabilities=%v but reported %v",
			p.ID, verified.RuntimeCapabilities, p.ReportedRuntimeCapabilities)
	}
	if verified.MetallibHash != metallibHash {
		return fmt.Sprintf("provider %s signed mlx_metallib=%q but reported %q",
			p.ID, verified.MetallibHash, metallibHash)
	}
	return ""
}

func capabilitySet(values []string) map[string]struct{} {
	set := make(map[string]struct{}, len(values))
	for _, value := range values {
		set[value] = struct{}{}
	}
	return set
}
