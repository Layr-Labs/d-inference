// Package admission evaluates capacity policy on detached values. It owns no
// registry state; callers must revalidate decisions before reserving capacity.
package admission

// BudgetDecision distinguishes an authoritative budget result from a legacy
// provider that still needs the cold-load and physical-memory checks.
type BudgetDecision uint8

const (
	NeedsMemoryCheck BudgetDecision = iota
	Admit
	Reject
)

// SlotBudget is the model-local heartbeat and coordinator reservation snapshot.
type SlotBudget struct {
	Blocked, Clamped                                           bool
	Used, Queued, Maximum, Potential, Pending, KVBytesPerToken int64
}

// CommittedTokens is the heartbeat-visible baseline for pending de-duplication.
func CommittedTokens(used, queued, potential int64) int64 {
	committed := used + queued
	if potential > committed {
		committed = potential
	}
	if committed < 0 {
		return 0
	}
	return committed
}

// CheckSlot retains the model-local zero-budget fence even when a co-resident
// model has spare pooled capacity. A positive budget bypasses legacy memory math.
func CheckSlot(slot SlotBudget, requestTokens int64) BudgetDecision {
	if slot.Blocked || slot.Clamped || (slot.Maximum <= 0 && slot.KVBytesPerToken > 0) {
		return Reject
	}
	if slot.Maximum > 0 {
		extra := slot.Pending - CommittedTokens(slot.Used, slot.Queued, slot.Potential)
		if extra < 0 {
			extra = 0
		}
		if slot.Used+slot.Queued+extra+requestTokens > slot.Maximum {
			return Reject
		}
		return Admit
	}
	return NeedsMemoryCheck
}

// PoolBudget contains only totals, not the mutable provider's per-model table.
// Rate is the caller-resolved (bounded, conservative for cold models) byte rate.
type PoolBudget struct {
	Reported, ByteMode, PendingBytesKnown                     bool
	Total, Used, Committed, Pending                           int64
	TotalBytes, UsedBytes, CommittedBytes, PendingBytes, Rate int64
}

// PoolAdmits charges all models' pending work against the reconstructed pool.
func PoolAdmits(pool PoolBudget, requestTokens int64) bool {
	if !pool.Reported {
		return true
	}
	if pool.Total <= 0 {
		return requestTokens == 0
	}
	if pool.ByteMode && pool.PendingBytesKnown && pool.Rate > 0 {
		extra := pool.PendingBytes - pool.CommittedBytes
		if extra < 0 {
			extra = 0
		}
		remaining := pool.TotalBytes - pool.UsedBytes
		if remaining < 0 || extra > remaining || requestTokens < 0 {
			return false
		}
		return requestTokens <= (remaining-extra)/pool.Rate
	}
	extra := pool.Pending - pool.Committed
	if extra < 0 {
		extra = 0
	}
	remaining := pool.Total - pool.Used
	if remaining < 0 || extra > remaining || requestTokens < 0 {
		return false
	}
	return requestTokens <= remaining-extra
}

// PoolRemaining returns -1 for an unreported pool, otherwise model-local tokens.
func PoolRemaining(pool PoolBudget) int64 {
	if !pool.Reported {
		return -1
	}
	if pool.Total <= 0 {
		return 0
	}
	if pool.ByteMode && pool.PendingBytesKnown && pool.Rate > 0 {
		extra := pool.PendingBytes - pool.CommittedBytes
		if extra < 0 {
			extra = 0
		}
		remaining := pool.TotalBytes - pool.UsedBytes
		if remaining <= 0 || extra >= remaining {
			return 0
		}
		return (remaining - extra) / pool.Rate
	}
	extra := pool.Pending - pool.Committed
	if extra < 0 {
		extra = 0
	}
	remaining := pool.Total - pool.Used
	if remaining <= 0 || extra >= remaining {
		return 0
	}
	return remaining - extra
}
