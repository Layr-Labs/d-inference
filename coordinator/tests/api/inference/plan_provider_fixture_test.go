package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// planWiringProvider registers a fully-routable provider through the exported
// registry surface (the api-side mirror of the registry package's
// makeTokenBudgetProvider fixture): trusted, manifest-checked, E2E-capable,
// with a running model-resident slot whose token-budget backlog dominates
// routing cost, so winner and plan order are deterministic. The connection is
// nil, so no provider writer exists: a reservation succeeds, the funnel
// prepares and encrypts, and the deferred write then fails deterministically
// ("failed to send request to provider") — which lets tests observe that an
// entry went through the single prepare/encrypt/write funnel without a live
// provider socket.
func planWiringProvider(t *testing.T, reg *registry.Registry, id, model string, backlogTokens int64) *registry.Provider {
	t.Helper()
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			ChipFamily:         "M3",
			ChipTier:           "Max",
			MemoryGB:           64,
			MemoryAvailableGB:  60,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
			MemoryBandwidthGBs: 400,
		},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		DecodeTPS:               100,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			SIPEnabled:           true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			ActiveTokenBudgetUsed: backlogTokens,
			ActiveTokenBudgetMax:  1_000_000,
			ObservedDecodeTPS:     80,
		}},
	}
	p.Mu().Unlock()
	return p
}
