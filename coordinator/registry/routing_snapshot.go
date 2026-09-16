package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// fillRoutingSnapshotPLocked projects provider state for routing and public
// capacity preflight. Caller holds r.mu (either mode) and p.mu and has already
// applied its routing gates. It overwrites caller-owned storage, so reused
// snapshots cannot retain slots or budgets from another model/provider.
// Selection-only headroom and heartbeat-age fields are filled by its caller.
func (r *Registry) fillRoutingSnapshotPLocked(snap *routingSnapshot, p *Provider, model string, now time.Time) {
	*snap = routingSnapshot{}
	snap.Provider = p
	snap.Model = model
	snap.ChipFamily = p.Hardware.ChipFamily
	snap.BinaryVersion = p.Version
	snap.SlotState = "unknown"
	snap.TotalPending = p.pendingCount()
	snap.SystemMetrics = p.SystemMetrics
	snap.DecodeTPS = resolvedDecodeTPS(p)
	snap.PrefillTPS = resolvedPrefillTPS(p)
	snap.TotalMemoryGB = float64(p.Hardware.MemoryGB)
	snap.ModelSizeGB = r.modelSizeGBForFitLocked(p, model)
	snap.MinRAMGB = r.catalogMinRAMGbLocked(model)

	fillSnapshotPendingAndPool(snap, p, model)

	snap.HasBackendCapacity = p.BackendCapacity != nil

	if p.BackendCapacity != nil {
		snap.GPUMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
		snap.FreeForLoadGB = p.BackendCapacity.FreeForLoadGB
		if p.BackendCapacity.TotalMemoryGB > 0 {
			snap.TotalMemoryGB = p.BackendCapacity.TotalMemoryGB
		}
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			snap.SlotState = slot.State
			snap.BackendRunning = int(slot.NumRunning)
			snap.BackendWaiting = int(slot.NumWaiting)
			snap.MaxTokensPotential = slot.MaxTokensPotential
			snap.ObservedDecodeTPS = slot.ObservedDecodeTPS
			snap.ObservedPrefillTPS = slot.ObservedPrefillTPS
			snap.ActiveTokenBudgetUsed = slot.ActiveTokenBudgetUsed
			snap.ActiveTokenBudgetMax = slot.ActiveTokenBudgetMax
			snap.QueuedTokenBudget = slot.QueuedTokenBudget
			snap.KVBytesPerToken = clampKVBytesPerToken(slot.KVBytesPerToken)
			snap.StepsExecuted = slot.StepsExecuted
			snap.Admits = slot.Admits
			snap.FirstTokensEmitted = slot.FirstTokensEmitted
			snap.SecondsSinceLastStep = slot.SecondsSinceLastStep
			snap.SecondsSinceLastFirstToken = slot.SecondsSinceLastFirstToken
			snap.WedgeSuspected = slot.WedgeSuspected
			snap.EvalInFlightMs = slot.EvalInFlightMs
			snap.IdleClearInFlightMs = slot.IdleClearInFlightMs
			break
		}
	}
	snap.ModelLoaded = routingcost.SlotStateModelLoaded(snap.SlotState)
	snap.AvailableOnDisk = !snap.ModelLoaded
	snap.FleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

	// Gray-box budget clamp (faultstate/budget_clamp.go): when a capacity-503 has proven
	// the pair's live gate is rejecting, admission must not believe the
	// stale-optimistic heartbeat budget. Evaluated for budgetless snapshots
	// too — a reconnected session has no BackendCapacity until its first
	// heartbeat, and a clamp armed on a budget-reporting pair must keep
	// holding through that window instead of shedding onto the legacy memory
	// path (never-budget-reporting legacy pairs stay exempt inside the check).
	// p.LastHeartbeat is when the CURRENT BackendCapacity was delivered
	// (Heartbeat stamps both in one critical section), which is what the
	// release-freshness check compares against the clamp time. p.mu and r.mu
	// are both held here (see lock discipline above); the clamp read is one
	// lock-free flag load unless the identity actually carries a clamp, and is
	// confirmed against p.faultSession like the gates above (gateView).
	rawRemaining := snap.ActiveTokenBudgetMax - snap.ActiveTokenBudgetUsed - snap.QueuedTokenBudget
	snap.BudgetClamped = r.budgetClampedFor(p, model, p.LastHeartbeat, rawRemaining, snap.ActiveTokenBudgetMax > 0, now)
}
