package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
		MaxModelSlots: 3,
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
