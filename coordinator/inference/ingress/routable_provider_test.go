package ingress

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func makeRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) *registry.Provider {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			MemoryGB:           64,
			MemoryBandwidthGBs: 400,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
		},
		Models: []protocol.ModelInfo{
			{ID: model, SizeBytes: 5_000_000_000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend:                 "mlx-swift",
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess:    true,
			TextProxyDisabled:       true,
			PythonRuntimeLocked:     true,
			DangerousModulesBlocked: true,
			SIPEnabled:              true,
			AntiDebugEnabled:        true,
			CoreDumpsDisabled:       true,
			EnvScrubbed:             true,
		},
	}
	p := reg.Register(id, nil, msg)
	// This helper constructs an already registered, routable fixture. Recovery
	// failure cases use their own pending-registration fixtures.
	p.CompleteProviderStateRestore()
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.DecodeTPS = 90.0
	p.PrefillTPS = 500.0
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     64,
		GPUMemoryActiveGB: 8,
		Slots: []protocol.BackendSlotCapacity{
			{Model: model, State: "running", NumRunning: 0, NumWaiting: 0},
		},
	}
	p.Mu().Unlock()
	return p
}

// makeVisionRoutableProvider registers an online, routable, vision-capable
// provider for model so a media request clears visionToolsFailFast and reaches
// the remote-media gate/resolution steps the HTTP-path tests below exercise.
// Nil test catalog => IsModelInCatalog/HasVisionProviderForModel allow it.
func makeVisionRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) {
	t.Helper()
	p := makeRoutableProvider(t, reg, id, model)
	p.Mu().Lock()
	for i := range p.Models {
		if p.Models[i].ID == model {
			p.Models[i].IsVision = true
		}
	}
	p.Mu().Unlock()
}
