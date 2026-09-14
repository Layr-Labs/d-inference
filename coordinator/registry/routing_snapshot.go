package registry

import "time"

// fillRoutingSnapshotPLocked projects provider state for routing and public
// capacity preflight. Caller holds r.mu (either mode) and p.mu and has already
// applied its routing gates. It overwrites caller-owned storage, so reused
// snapshots cannot retain slots or budgets from another model/provider.
// Selection-only headroom and heartbeat-age fields are filled by its caller.
func (r *Registry) fillRoutingSnapshotPLocked(snap *routingSnapshot, p *Provider, model string, now time.Time) {
	*snap = routingSnapshot{}
	snap.provider = p
	snap.model = model
	snap.chipFamily = p.Hardware.ChipFamily
	snap.binaryVersion = p.Version
	snap.slotState = "unknown"
	snap.totalPending = p.pendingCount()
	snap.systemMetrics = p.SystemMetrics
	snap.decodeTPS = resolvedDecodeTPS(p)
	snap.prefillTPS = resolvedPrefillTPS(p)
	snap.totalMemoryGB = float64(p.Hardware.MemoryGB)
	snap.modelSizeGB = r.modelSizeGBForFitLocked(p, model)
	snap.minRAMGb = r.catalogMinRAMGbLocked(model)

	fillSnapshotPendingAndPool(snap, p, model)

	snap.hasBackendCapacity = p.BackendCapacity != nil

	if p.BackendCapacity != nil {
		snap.gpuMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
		snap.freeForLoadGB = p.BackendCapacity.FreeForLoadGB
		if p.BackendCapacity.TotalMemoryGB > 0 {
			snap.totalMemoryGB = p.BackendCapacity.TotalMemoryGB
		}
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			snap.slotState = slot.State
			snap.backendRunning = int(slot.NumRunning)
			snap.backendWaiting = int(slot.NumWaiting)
			snap.maxTokensPotential = slot.MaxTokensPotential
			snap.observedDecodeTPS = slot.ObservedDecodeTPS
			snap.observedPrefillTPS = slot.ObservedPrefillTPS
			snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
			snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
			snap.queuedTokenBudget = slot.QueuedTokenBudget
			snap.kvBytesPerToken = clampKVBytesPerToken(slot.KVBytesPerToken)
			snap.stepsExecuted = slot.StepsExecuted
			snap.admits = slot.Admits
			snap.firstTokensEmitted = slot.FirstTokensEmitted
			snap.secondsSinceLastStep = slot.SecondsSinceLastStep
			snap.secondsSinceLastFirstToken = slot.SecondsSinceLastFirstToken
			snap.wedgeSuspected = slot.WedgeSuspected
			snap.evalInFlightMs = slot.EvalInFlightMs
			snap.idleClearInFlightMs = slot.IdleClearInFlightMs
			break
		}
	}
	snap.modelLoaded = slotStateModelLoaded(snap.slotState)
	snap.availableOnDisk = !snap.modelLoaded
	snap.fleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

	// Gray-box budget clamp (budget_clamp.go): when a capacity-503 has proven
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
	// confirmed against p.gate like the gates above (gateView).
	rawRemaining := snap.activeTokenBudgetMax - snap.activeTokenBudgetUsed - snap.queuedTokenBudget
	snap.budgetClamped = r.budgetClampedFor(p, model, p.LastHeartbeat, rawRemaining, snap.activeTokenBudgetMax > 0, now)
}
