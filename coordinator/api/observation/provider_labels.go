package observation

import (
	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
)

func SanitizeChipFamilyTag(family string) string {
	family = strings.TrimSpace(family)
	switch family {
	case "", "Unknown":
		return "unknown"
	case "M1", "M1 Pro", "M1 Max", "M1 Ultra",
		"M2", "M2 Pro", "M2 Max", "M2 Ultra",
		"M3", "M3 Pro", "M3 Max", "M3 Ultra",
		"M4", "M4 Pro", "M4 Max", "M4 Ultra",
		"M5", "M5 Pro", "M5 Max", "M5 Ultra", "M6":
		return strings.ReplaceAll(family, " ", "_")
	default:
		return "other"
	}
}

func ProviderChipFamily(p *registry.Provider) string {
	if p == nil {
		return ""
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.Hardware.ChipFamily
}

// ProviderVersionTag reads the provider's reported binary version under its
// lock and fences it to a bounded, tag-safe value.
func ProviderVersionTag(p *registry.Provider) string {
	if p == nil {
		return "unknown"
	}
	p.Mu().Lock()
	version := p.Version
	p.Mu().Unlock()
	return metriclabels.Version(version)
}

func BoolGauge(value bool) float64 {
	if value {
		return 1
	}
	return 0
}
