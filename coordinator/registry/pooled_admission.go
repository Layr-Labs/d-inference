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
//
// Units: the shared pool is physically BYTES of unified memory, and
// co-resident models spend it at different per-token rates
// (BackendSlotCapacity.KVBytesPerToken — a 26B model's token costs ~10× a
// small model's), so tokens are not a common unit across slots. When every
// budget slot reports its KV rate, the pool and all charges against it are
// normalized into bytes; otherwise (any legacy slot, or a pending/incoming
// request whose model has no reported rate) the check falls back to token
// accounting, which is exactly the pre-byte behavior. Token accounting
// denominates the pool in the LARGEST per-slot free-token view (the
// smallest-KV model's), so a big-KV model's pending burst is under-charged
// against it — the byte form is what makes a small-KV model's burst visible
// to a big-KV co-resident and vice versa.

// pooledTokenBudget is a provider's reconstructed whole-box token budget,
// carried in token units always and additionally in byte units when every
// budget slot reports KVBytesPerToken (byteMode).
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

	// usedBytes / committedBytes / totalBytes are the byte-normalized analogs
	// of used / committed / total: each slot's token quantities × that slot's
	// KVBytesPerToken, with the shared free headroom again counted once (the
	// largest per-slot free BYTE view — in byte space every slot observes the
	// same shared pool). Only meaningful when byteMode is true.
	usedBytes      int64
	committedBytes int64
	totalBytes     int64
	// byteMode is true when there is at least one budget slot and EVERY budget
	// slot reports KVBytesPerToken > 0, i.e. the pool can be reconstructed in
	// bytes. False ⇒ pooledBudgetAdmits uses token accounting exactly.
	byteMode bool
	// kvBytesPerToken maps each budget slot's model to its reported per-token
	// KV rate, for normalizing coordinator-pending charges into bytes. Nil
	// when no budget slot reports a rate.
	kvBytesPerToken map[string]int64
}

// providerPooledTokenBudget reconstructs the provider's pooled budget from its
// backend slots. Slots without a token budget (ActiveTokenBudgetMax <= 0) are
// ignored and negative per-slot values floored, mirroring providerTokenBudget.
// A nil/empty slice (or no budget slots at all) yields the zero value, which
// pooledBudgetAdmits treats as "no pooled constraint".
func providerPooledTokenBudget(slots []protocol.BackendSlotCapacity) pooledTokenBudget {
	used, total := providerTokenBudget(slots)
	pool := pooledTokenBudget{used: used, total: total, byteMode: true}
	budgetSlots := 0
	var sharedFreeBytes int64
	for _, slot := range slots {
		if slot.ActiveTokenBudgetMax <= 0 {
			continue
		}
		budgetSlots++
		slotUsed := slot.ActiveTokenBudgetUsed + slot.QueuedTokenBudget
		if slotUsed < 0 {
			slotUsed = 0
		}
		c := slot.ActiveTokenBudgetUsed + slot.QueuedTokenBudget
		if slot.MaxTokensPotential > c {
			c = slot.MaxTokensPotential
		}
		if c < 0 {
			c = 0
		}
		pool.committed += c
		if slot.KVBytesPerToken <= 0 {
			// A budget slot without a KV rate makes byte reconstruction
			// impossible for the whole pool (legacy provider build).
			pool.byteMode = false
			continue
		}
		if pool.kvBytesPerToken == nil {
			pool.kvBytesPerToken = make(map[string]int64, len(slots))
		}
		pool.kvBytesPerToken[slot.Model] = slot.KVBytesPerToken
		pool.usedBytes += slotUsed * slot.KVBytesPerToken
		pool.committedBytes += c * slot.KVBytesPerToken
		// Per-slot free headroom in bytes; all slots see the same shared byte
		// pool, so the largest is the live shared headroom (counted once).
		if free := (slot.ActiveTokenBudgetMax - slotUsed) * slot.KVBytesPerToken; free > sharedFreeBytes {
			sharedFreeBytes = free
		}
	}
	if budgetSlots == 0 {
		pool.byteMode = false
	}
	pool.totalBytes = pool.committedBytes + sharedFreeBytes
	return pool
}

// pooledBudgetAdmits reports whether a request of requestTokens fits the
// provider's shared pool once every model's coordinator-side pending tokens
// (snap.pendingMaxTokensAllModels / snap.pendingMaxBytesAllModels) are charged
// against it. The subtraction of the committed baseline mirrors the per-slot
// check's committedTokenBudget subtraction (avoid double-counting requests the
// heartbeat already reflects), floored at zero. total <= 0 means the provider
// reported no pooled budget (legacy provider, or a snapshot built without
// backend capacity) — no pooled constraint, the caller's other gates decide.
//
// The check runs in BYTES when the pool is byte-reconstructable (byteMode),
// every pending charge was normalizable (snap.pendingBytesKnown), and the
// incoming request's own KV rate is known (snap.kvBytesPerToken — this
// model's slot; 0 for a cold/absent slot). Any gap falls back to token
// accounting, which is byte-for-byte the legacy-provider behavior.
func pooledBudgetAdmits(snap routingSnapshot, requestTokens int64) bool {
	pool := snap.pooledTokenBudget
	if pool.total <= 0 {
		return true
	}
	if pool.byteMode && snap.pendingBytesKnown && snap.kvBytesPerToken > 0 {
		extra := snap.pendingMaxBytesAllModels - pool.committedBytes
		if extra < 0 {
			extra = 0
		}
		return pool.usedBytes+extra+requestTokens*snap.kvBytesPerToken <= pool.totalBytes
	}
	extra := int64(snap.pendingMaxTokensAllModels) - pool.committed
	if extra < 0 {
		extra = 0
	}
	return pool.used+extra+requestTokens <= pool.total
}
