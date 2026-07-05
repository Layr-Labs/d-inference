package registry

import (
	"log/slog"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Shared model-build fixtures used by the dedicated-models, concurrency-cap,
// and warm-pool tests.
const (
	gemmaBuild     = "gemma-4-26b-qat-4bit"
	gemmaBuildOrg  = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	gemmaBuildSmol = "gemma-4-12b-qat-4bit"
	qwenBuild      = "qwen-3-32b"
)

// addAdvertisedModel appends an advertised model id to an already-registered
// provider (makeSchedulerProvider gives it exactly one). Mirrors how a real
// multi-model provider advertises its on-disk catalog.
func addAdvertisedModel(p *Provider, modelID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: modelID, ModelType: "chat", Quantization: "4bit"})
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

func testRegisterMessage() *protocol.RegisterMessage {
	return &protocol.RegisterMessage{
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
		Models: []protocol.ModelInfo{
			{
				ID:           "mlx-community/Qwen3.5-9B-Instruct-4bit",
				SizeBytes:    5700000000,
				ModelType:    "qwen3",
				Quantization: "4bit",
			},
		},
		Backend:                 BackendMLXSwift,
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
}

// testMakeTextRoutable sets the fields required for a provider to be routable
// for text models: trust level, challenge freshness, manifest verification,
// and coordinator-verified SIP.
func testMakeTextRoutable(p *Provider) {
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	p.RuntimeManifestChecked = true
}

// findRoutableProvider selects a provider for model via the PRODUCTION routing
// path (ReserveProviderEx), releases the reserved capacity, and returns the
// selected provider — or nil when no provider can serve the model right now.
// It replaces the removed score-based FindProvider as a routability probe in
// tests: the production path applies the same structural/privacy/trust/challenge
// gates, so "is this provider routable?" assertions hold without a parallel
// routing implementation to keep in sync.
func findRoutableProvider(r *Registry, model string) *Provider {
	pr := &PendingRequest{RequestID: "test-route-probe", Model: model, RequestedMaxTokens: 64}
	p, _ := r.ReserveProviderEx(model, pr)
	if p != nil {
		p.RemovePending(pr.RequestID)
		r.SetProviderIdle(p.ID)
	}
	return p
}
