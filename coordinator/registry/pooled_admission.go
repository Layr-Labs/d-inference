package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// pooled_admission.go — provider-level (all-models) token-budget admission.
//
// A provider's per-model slots do NOT own private KV budgets: each slot's
// ActiveTokenBudgetMax is (that slot's committed tokens) + the box's ONE
// shared live KV headroom (see providerTokenBudget, utilization.go). The
// per-slot admission check in freeMemoryAdmits therefore lets two co-resident
// models double-spend the shared pool inside the ~30s heartbeat gap: a burst
// admitted against model A's slot max is invisible to model B's slot max
// until the next heartbeat re-reports both. The pooled check here closes that
// gap by admitting against the reconstructed whole-box pool with ALL models'
// coordinator-pending tokens counted. Inert for single-model providers (the
// pool reduces to the slot's own budget and the arithmetic matches the
// per-slot check exactly) and for legacy providers that report no token
// budget (total = 0).

// pooledTokenBudget is a provider's reconstructed whole-box token budget.
type pooledTokenBudget struct {
	// used is Σ (ActiveTokenBudgetUsed + QueuedTokenBudget) across budget
	// slots — reservations the provider itself reports as live.
	used int64
	// committed is the all-slots analog of committedTokenBudget: Σ per slot of
	// max(used+queued, MaxTokensPotential). It is the heartbeat-visible
	// commitment baseline subtracted from coordinator-pending tokens so
	// requests the provider already accounts for are not double-counted.
	committed int64
	// total is the pooled capacity from providerTokenBudget: committed tokens
	// (which add across slots) plus the shared free headroom counted exactly
	// once (per-slot maxes are NOT additive).
	total int64
}

// providerPooledTokenBudget reconstructs the provider's pooled budget from its
// backend slots. Slots without a token budget (ActiveTokenBudgetMax <= 0) are
// ignored and negative per-slot values floored, mirroring providerTokenBudget.
// A nil/empty slice (or no budget slots at all) yields the zero value, which
// pooledBudgetAdmits treats as "no pooled constraint".
func providerPooledTokenBudget(slots []protocol.BackendSlotCapacity) pooledTokenBudget {
	used, total := providerTokenBudget(slots)
	var committed int64
	for _, slot := range slots {
		if slot.ActiveTokenBudgetMax <= 0 {
			continue
		}
		c := slot.ActiveTokenBudgetUsed + slot.QueuedTokenBudget
		if slot.MaxTokensPotential > c {
			c = slot.MaxTokensPotential
		}
		if c < 0 {
			c = 0
		}
		committed += c
	}
	return pooledTokenBudget{used: used, committed: committed, total: total}
}

// pooledBudgetAdmits reports whether a request of requestTokens fits the
// provider's shared pool once every model's coordinator-side pending tokens
// (pendingMaxTokensAllModels) are charged against it. The subtraction of
// pool.committed mirrors the per-slot check's committedTokenBudget subtraction
// (avoid double-counting requests the heartbeat already reflects), floored at
// zero. total <= 0 means the provider reported no pooled budget (legacy
// provider, or a snapshot built without backend capacity) — no pooled
// constraint, the caller's other gates decide.
func pooledBudgetAdmits(pool pooledTokenBudget, pendingMaxTokensAllModels int, requestTokens int64) bool {
	if pool.total <= 0 {
		return true
	}
	extra := int64(pendingMaxTokensAllModels) - pool.committed
	if extra < 0 {
		extra = 0
	}
	return pool.used+extra+requestTokens <= pool.total
}
