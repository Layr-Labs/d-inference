package inference

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// reportIdleFirstContentEvidence supplies a changing measured EWMA through two
// real heartbeat applications. A single initial report proves no sample age.
func reportIdleFirstContentEvidence(reg *registry.Registry, providerID, model string) {
	for i, rate := range []float64{3999, 4000} {
		zero, initialized := int64(0), true
		reg.Heartbeat(providerID, &protocol.HeartbeatMessage{
			Type: protocol.TypeHeartbeat, Status: "idle", WarmModels: []string{model},
			BackendCapacity: &protocol.BackendCapacity{
				CapacitySeq: uint64(i + 1), TotalMemoryGB: 64,
				Slots: []protocol.BackendSlotCapacity{{
					Model: model, State: "idle", MaxConcurrency: 4,
					ActiveTokenBudgetMax: 1_000_000, ObservedDecodeTPS: float64(199 + i),
					ObservedPrefillTPS: rate,
					Telemetry: &protocol.SlotTelemetry{
						QueuedPrefillTokens: &zero, PartialPrefillRows: &zero,
						IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized,
					},
				}},
			},
		})
	}
}
