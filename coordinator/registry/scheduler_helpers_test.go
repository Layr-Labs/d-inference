package registry

import (
	"testing"

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
	testMakeTextRoutable(p)
	p.RuntimeVerified = true
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
	if p.AttestationResult == nil {
		p.AttestationResult = &attestation.VerificationResult{
			Valid: true, PublicKey: "test-se-" + p.ID,
		}
	}
	p.AttestationResult.SerialNumber = serial
	p.DeviceEvidence.Serial = serial
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
