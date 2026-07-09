package registry

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
// normalized into bytes. A pending/incoming request whose cold model has no
// reported rate is charged at a bounded conservative default so it cannot
// disable byte accounting for a reconstructable pool. Otherwise (any legacy
// slot) the check falls back to token accounting, exactly the pre-byte behavior.
// Token accounting denominates the pool in the LARGEST per-slot free-token view (the
// smallest-KV model's), so a big-KV model's pending burst is under-charged
// against it — the byte form is what makes a small-KV model's burst visible
// to a big-KV co-resident and vice versa.

// maxKVBytesPerToken bounds a slot's reported per-token KV cost before it enters
// byte-pool math. Heartbeat token counts are clamped to ~10B upstream, but
// slot.KVBytesPerToken is UNBOUNDED — a garbage or malicious rate multiplied by
// a large token count overflows int64 to a negative usedBytes/totalBytes, which
// silently breaks admission (a negative pool total either rejects everything or,
// with a negative left side, admits everything). 16 MiB/token is ~160× gemma's
// real ~100 kB/token, so every legitimate rate passes untouched; the product
// with the 10B-token clamp is 1.68e17, and the per-slot sums stay far below
// int64max (9.2e18).
const maxKVBytesPerToken = 1 << 24 // 16 MiB per token

// clampKVBytesPerToken floors a per-token KV rate at 0 and caps it at
// maxKVBytesPerToken so byte-pool products cannot overflow. A negative rate is
// treated as absent (0), matching the pool's "no byte rate" handling.
func clampKVBytesPerToken(r int64) int64 {
	if r < 0 {
		return 0
	}
	if r > maxKVBytesPerToken {
		return maxKVBytesPerToken
	}
	return r
}

// resolvedPooledKVBytesPerToken returns the byte rate used by every pooled-KV
// charge. A positive provider-reported model rate is clamped and preserved. A
// cold/unknown model on a byte-reconstructable pool is priced at the larger of
// the coordinator's conservative cold-model default and the largest resident
// rate. Resident rates alone cannot safely estimate a different model that has
// not loaded yet, while retaining a higher observed resident rate avoids
// weakening the fallback. Legacy/non-reconstructable pools return 0 and retain
// token accounting.
func resolvedPooledKVBytesPerToken(pool pooledTokenBudget, reportedRate int64) int64 {
	if !pool.byteMode {
		return 0
	}
	if rate := clampKVBytesPerToken(reportedRate); rate > 0 {
		return rate
	}
	rate := int64(kvCacheBytesPerToken)
	if pool.maxResidentKVBytesPerToken > rate {
		rate = pool.maxResidentKVBytesPerToken
	}
	return clampKVBytesPerToken(rate)
}

// addPooledKVByteCharge adds tokens*rate without wrapping. An overflowed
// pending charge must reject against every finite pool, so saturation at
// MaxInt64 is both conservative and sufficient for admission/capacity math.
func addPooledKVByteCharge(total, tokens, rate int64) int64 {
	if total >= math.MaxInt64 {
		return math.MaxInt64
	}
	if tokens <= 0 || rate <= 0 {
		return total
	}
	if tokens > (math.MaxInt64-total)/rate {
		return math.MaxInt64
	}
	return total + tokens*rate
}

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
	// maxResidentKVBytesPerToken is the largest clamped rate among budget
	// slots. It can raise, but never lower, the conservative cold-model default.
	maxResidentKVBytesPerToken int64
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
		// Clamp the raw rate ONCE (overflow guard, see maxKVBytesPerToken) and
		// use the clamped value for the map store and every byte product below.
		rate := clampKVBytesPerToken(slot.KVBytesPerToken)
		if rate <= 0 {
			// A budget slot without a KV rate makes byte reconstruction
			// impossible for the whole pool (legacy provider build).
			pool.byteMode = false
			continue
		}
		if pool.kvBytesPerToken == nil {
			pool.kvBytesPerToken = make(map[string]int64, len(slots))
		}
		pool.kvBytesPerToken[slot.Model] = rate
		if rate > pool.maxResidentKVBytesPerToken {
			pool.maxResidentKVBytesPerToken = rate
		}
		pool.usedBytes += slotUsed * rate
		pool.committedBytes += c * rate
		// Per-slot free headroom in bytes; all slots see the same shared byte
		// pool, so the largest is the live shared headroom (counted once).
		if free := (slot.ActiveTokenBudgetMax - slotUsed) * rate; free > sharedFreeBytes {
			sharedFreeBytes = free
		}
	}
	if budgetSlots == 0 {
		pool.byteMode = false
	}
	// totalBytes mirrors the token path's total (providerTokenBudget: LIVE
	// used + shared free), NOT committed+potential. committedBytes carries
	// MaxTokensPotential only as the pending de-dup baseline (subtracted in
	// pooledBudgetAdmits' extra); adding it into the pool total too would
	// double-count a co-resident slot's not-yet-materialized future growth as
	// extra physical KV capacity, letting an in-gap burst overcommit the box.
	pool.totalBytes = pool.usedBytes + sharedFreeBytes
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
// The check runs in BYTES when the pool is byte-reconstructable (byteMode) and
// every pending charge was normalizable (snap.pendingBytesKnown). The single
// resolvedPooledKVBytesPerToken policy prices both resident and cold/absent
// requests: resident rates are preserved after clamping; cold unknown rates use
// at least the conservative default, never a cheap resident-only estimate.
// Token accounting is used only when the pool is not byte-reconstructable or
// the snapshot predates/omits byte accumulation.
func pooledBudgetAdmits(snap routingSnapshot, requestTokens int64) bool {
	pool := snap.pooledTokenBudget
	if pool.total <= 0 {
		return true
	}
	if pool.byteMode && snap.pendingBytesKnown {
		reqRate := resolvedPooledKVBytesPerToken(pool, snap.kvBytesPerToken)
		if reqRate > 0 {
			extra := snap.pendingMaxBytesAllModels - pool.committedBytes
			if extra < 0 {
				extra = 0
			}
			remaining := pool.totalBytes - pool.usedBytes
			if remaining < 0 || extra > remaining || requestTokens < 0 {
				return false
			}
			return requestTokens <= (remaining-extra)/reqRate
		}
	}
	extra := int64(snap.pendingMaxTokensAllModels) - pool.committed
	if extra < 0 {
		extra = 0
	}
	remaining := pool.total - pool.used
	if remaining < 0 || extra > remaining || requestTokens < 0 {
		return false
	}
	return requestTokens <= remaining-extra
}

// pooledRemainingTokens is the capacity-snapshot analog of pooledBudgetAdmits:
// how many tokens of a model whose per-token KV rate is modelRate still fit the
// shared pool once every model's coordinator-pending tokens are charged.
// pooledBudgetAdmits(snap, n) admits iff n <= pooledRemainingTokens(pool, …,
// snap.kvBytesPerToken) with the same inputs, so the public capacity feed
// (/v1/models[/capacity]) cannot advertise pooled headroom the admission gate
// refuses. Both branch identically: BYTES when the pool is byte-reconstructable
// (byteMode) and every pending charge normalized (pendingBytesKnown), pricing
// this model through resolvedPooledKVBytesPerToken — the same known/default
// policy pooledBudgetAdmits uses — so the two stay equivalent. Token accounting
// only when !byteMode or !pendingBytesKnown. Returns -1 when the provider
// reports no pooled budget
// (total <= 0) — the "no pooled constraint" sentinel that leaves the per-slot
// numbers unclamped.
func pooledRemainingTokens(pool pooledTokenBudget, pendingTokensAllModels int, pendingBytesAllModels int64, pendingBytesKnown bool, modelRate int64) int64 {
	if pool.total <= 0 {
		return -1
	}
	if pool.byteMode && pendingBytesKnown {
		rate := resolvedPooledKVBytesPerToken(pool, modelRate)
		if rate > 0 {
			extra := pendingBytesAllModels - pool.committedBytes
			if extra < 0 {
				extra = 0
			}
			remBytes := pool.totalBytes - pool.usedBytes
			if remBytes <= 0 || extra >= remBytes {
				return 0
			}
			return (remBytes - extra) / rate
		}
	}
	extra := int64(pendingTokensAllModels) - pool.committed
	if extra < 0 {
		extra = 0
	}
	rem := pool.total - pool.used
	if rem <= 0 || extra >= rem {
		return 0
	}
	return rem - extra
}
