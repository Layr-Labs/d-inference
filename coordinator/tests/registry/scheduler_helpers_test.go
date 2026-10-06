package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func makeSchedulerProvider(t *testing.T, reg *production.Registry, id, model string, decodeTPS float64, advertised ...string) *production.Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	for _, modelID := range advertised {
		msg.Models = append(msg.Models, protocol.ModelInfo{ID: modelID, ModelType: "chat", Quantization: "4bit"})
	}
	msg.DecodeTPS = decodeTPS
	return makeSchedulerProviderWithRegistration(t, reg, id, model, msg)
}

func makeSchedulerProviderWithRegistration(t *testing.T, reg *production.Registry, id, model string, msg *protocol.RegisterMessage) *production.Provider {
	t.Helper()
	p := reg.Register(id, nil, msg)
	p.Mu().Lock()
	p.TrustLevel = production.TrustHardware
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
	p.Mu().Unlock()
	return p
}

func setSchedulerProviderSerial(p *production.Provider, serial string) {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
}

func makeTokenBudgetProvider(t *testing.T, reg *production.Registry, id, model string, decodeTPS float64, budgetUsed, budgetMax int64, observedTPS float64) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, decodeTPS)
	p.Mu().Lock()
	if len(p.BackendCapacity.Slots) > 0 {
		p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = budgetUsed
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = budgetMax
		p.BackendCapacity.Slots[0].ObservedDecodeTPS = observedTPS
	}
	p.Mu().Unlock()
	return p
}
