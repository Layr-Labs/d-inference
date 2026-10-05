package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// The frozen arithmetic fixture used Version="test" on an unregistered box.
// Integrated cases match a supported registration version on both identities;
// this synthetic catalog is injected locally and never promotes release data.
func reviewedServingProvider(t *testing.T, configure ...func(*production.Dependencies)) (*production.Registry, *production.Provider, *performance.Profile) {
	t.Helper()
	identity, profile, _ := reviewedProfileEvidence(t)
	msg := testRegisterMessage()
	msg.Version = "1.0.0"
	profile.ProviderVersion = msg.Version
	msg.Hardware = identity.Hardware
	msg.Models = identity.Models
	msg.Models[0].ModelType, msg.Models[0].Quantization = "chat", "4bit"
	catalog := performance.NewCatalog(profile)
	deps := production.Dependencies{
		PerformanceProfiles: catalog, QualityPolicy: &quality.Policy{},
	}
	for _, apply := range configure {
		apply(&deps)
	}
	reg := production.NewWithDependencies(testLogger(), deps)
	p := reg.Register("reviewed", nil, msg)
	// The composed registration path binds version with this real operation.
	p.SetVersion(msg.Version)
	p.Mu().Lock()
	testMakeTextRoutable(p)
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: .1, CPUUsage: .1, ThermalState: "nominal"}
	p.BackendCapacity = identity.Capacity
	p.BackendCapacity.Slots[0].State = "idle"
	p.Mu().Unlock()
	return reg, p, profile
}
