package registry_test

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const defaultBudgetClampTTL = 5 * time.Minute

// grayBoxBudget mirrors the incident heartbeat: ~72k used of ~5.2M advertised.
const (
	grayBoxBudgetUsed = int64(72_000)
	grayBoxBudgetMax  = int64(5_200_000)
)

// sendBudgetHeartbeat drives the REAL heartbeat path (the same one prod
// heartbeats take), delivering a fresh BackendCapacity snapshot with the given
// slot budget. LastHeartbeat and BackendCapacity are stamped in the same
// critical section, which is exactly the freshness anchor the clamp release
// compares against.
func sendBudgetHeartbeat(r *production.Registry, providerID, model string, used, max int64) {
	active := model
	r.Heartbeat(providerID, &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "idle",
		ActiveModel: &active,
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal",
		},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{{
				Model:                 model,
				State:                 "running",
				ActiveTokenBudgetUsed: used,
				ActiveTokenBudgetMax:  max,
			}},
		},
	})
}

// reserveOnce runs the production reservation path once and releases the
// reservation, returning the selected provider (nil = no route) and decision.
func reserveOnce(r *production.Registry, model, requestID string) (*production.Provider, production.RoutingDecision) {
	p, decision := r.ReserveProviderEx(model, &production.PendingRequest{
		RequestID:             requestID,
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    256,
	})
	if p != nil {
		p.RemovePending(requestID)
		r.SetProviderIdle(p.ID)
	}
	return p, decision
}

func newBudgetClampRegistry() (*production.Registry, *identitygate.Directory) {
	gates := identitygate.New(testLogger(), nil)
	r := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
	return r, gates
}

// These fixtures have one model per identity. A retained clamp entry, including
// an inactive one, requires a provider budget snapshot before the next accept.
func budgetClampNeedsSnapshot(gates *identitygate.Directory, providerID, model string) bool {
	_, needsBudget, _ := gates.PrepareCapacityAccept(providerID, model, false)
	return needsBudget
}
