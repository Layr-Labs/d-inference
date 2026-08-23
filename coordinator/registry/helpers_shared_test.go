package registry

import (
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Shared model-build fixtures used by the dedicated-models, concurrency-cap,
// and warm-pool tests.
const (
	gemmaBuild     = "gemma-4-26b-qat-4bit"
	gemmaBuildOrg  = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	gemmaBuildSmol = "gemma-4-12b-qat-4bit"
	gptossBuild    = "gpt-oss-20b"
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

func makeSchedulerProvider(t *testing.T, reg *Registry, id, model string, decodeTPS float64) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = decodeTPS
	p := reg.Register(id, nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{
				Model:              model,
				State:              "running",
				NumRunning:         0,
				NumWaiting:         0,
				ActiveTokens:       0,
				MaxTokensPotential: 0,
			},
		},
	}
	p.mu.Unlock()
	return p
}

func setSchedulerProviderSerial(p *Provider, serial string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
}

func makeTokenBudgetProvider(t *testing.T, reg *Registry, id, model string, decodeTPS float64, budgetUsed, budgetMax int64, observedTPS float64) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, decodeTPS)
	p.mu.Lock()
	if len(p.BackendCapacity.Slots) > 0 {
		p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = budgetUsed
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = budgetMax
		p.BackendCapacity.Slots[0].ObservedDecodeTPS = observedTPS
	}
	p.mu.Unlock()
	return p
}

// schedulerScenarioProvider describes the scheduler signals varied by
// cross-provider ranking tests.
type schedulerScenarioProvider struct {
	id          string
	decodeTPS   float64
	totalMemGB  float64
	gpuActiveGB float64
	pending     int
	backendRun  int
	backendWait int
	slotState   string
}

func (sp schedulerScenarioProvider) register(t *testing.T, reg *Registry, model string) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = sp.decodeTPS
	msg.Hardware.MemoryGB = int(sp.totalMemGB)
	p := reg.Register(sp.id, nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	state := sp.slotState
	if state == "" {
		state = "running"
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     sp.totalMemGB,
		GPUMemoryActiveGB: sp.gpuActiveGB,
		Slots: []protocol.BackendSlotCapacity{{
			Model:      model,
			State:      state,
			NumRunning: sp.backendRun,
			NumWaiting: sp.backendWait,
		}},
	}
	for i := range sp.pending {
		p.addPendingLocked(&PendingRequest{
			RequestID:          fmt.Sprintf("%s-pending-%d", sp.id, i),
			Model:              model,
			RequestedMaxTokens: 256,
		})
	}
	p.mu.Unlock()
	return p
}

func reserveSchedulerScenario(reg *Registry, model string, reqMax int) *Provider {
	return reg.ReserveProvider(model, &PendingRequest{
		RequestID:          "scheduler-scenario-request",
		Model:              model,
		RequestedMaxTokens: reqMax,
	})
}
