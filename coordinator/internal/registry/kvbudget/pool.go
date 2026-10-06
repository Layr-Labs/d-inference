// Package kvbudget reconstructs detached, whole-provider KV budgets from slot
// reports. It owns no provider state or locks; callers account for pending work
// and commit reservations under the provider's lock.
package kvbudget

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

// Provider-level (all-models) token-budget reconstruction.
//
// The one-engine runtime re-slices the box's KV budget into private per-engine
// grants: each slot's ActiveTokenBudgetMax is that model's own grant, so the
// slot maxima are additive while each slot's own admission ceiling remains
// binding. The per-slot check alone cannot see two cases where one model's
// work spends capacity another model's check would still offer: a re-slice
// that shrank a grant below its live use (the excess is physically held, so
// it drains the box-wide total), and a COLD model that has no slot to check
// yet but lands in the same box after load. The pooled check reconstructs the
// box-wide pool (Σ grants) and charges ALL models' coordinator-pending tokens
// against it. Providers that report neither a token budget nor a KV rate
// remain unconstrained; a slot with a positive KV rate and a zero budget is
// authoritative known-zero capacity and fails closed.
//
// Units: the pool is physically BYTES of unified memory, and co-resident
// models spend it at different per-token rates
// (BackendSlotCapacity.KVBytesPerToken — a 26B model's token costs ~10× a
// small model's), so tokens are not a common unit across slots. When every
// budget slot reports its KV rate, the pool and all charges against it are
// normalized into bytes. A pending/incoming request whose cold model has no
// reported rate is charged at a bounded conservative default so it cannot
// disable byte accounting for a reconstructable pool. Otherwise (any budget
// slot without a rate) the check falls back to token accounting.

// MaxBytesPerToken bounds a slot's reported per-token KV cost before it enters
// byte-pool math. Heartbeat token counts are clamped to ~10B upstream, but
// slot.KVBytesPerToken is UNBOUNDED — a garbage or malicious rate multiplied by
// a large token count overflows int64 to a negative usedBytes/totalBytes, which
// silently breaks admission (a negative pool total either rejects everything or,
// with a negative left side, admits everything). 16 MiB/token is ~160× gemma's
// real ~100 kB/token, so every legitimate rate passes untouched; the product
// with the 10B-token clamp is 1.68e17, and the per-slot sums stay far below
// int64max (9.2e18).
const MaxBytesPerToken = 1 << 24 // 16 MiB per token

func addNonnegativeSaturating(total, value int64) int64 {
	if value <= 0 {
		return total
	}
	if total > math.MaxInt64-value {
		return math.MaxInt64
	}
	return total + value
}

// ClampRate floors a per-token KV rate at 0 and caps it at
// MaxBytesPerToken so byte-pool products cannot overflow. A negative rate is
// treated as absent (0), matching the pool's "no byte rate" handling.
func ClampRate(r int64) int64 {
	if r < 0 {
		return 0
	}
	if r > MaxBytesPerToken {
		return MaxBytesPerToken
	}
	return r
}

// ResolveRate returns the byte rate used by every pooled-KV
// charge. A positive provider-reported model rate is clamped and preserved. A
// cold/unknown model on a byte-reconstructable pool is priced at the larger of
// the coordinator's conservative cold-model default and the largest resident
// rate. Resident rates alone cannot safely estimate a different model that has
// not loaded yet, while retaining a higher observed resident rate avoids
// weakening the fallback. Legacy/non-reconstructable pools return 0 and retain
// token accounting.
func ResolveRate(pool *Budget, reportedRate int64) int64 {
	if !pool.ByteMode {
		return 0
	}
	if rate := ClampRate(reportedRate); rate > 0 {
		return rate
	}
	rate := int64(admission.KVCacheBytesPerToken)
	if pool.maxResidentKVBytesPerToken > rate {
		rate = pool.maxResidentKVBytesPerToken
	}
	return ClampRate(rate)
}

// KnownZero distinguishes an authoritative zero from an omitted
// legacy budget. Engine V2 reports KVBytesPerToken whenever it knows the model's
// rate, including when its live fleet clamp leaves room for zero tokens. That
// model-local zero must bind even if a co-resident model still has pooled
// headroom.
func KnownZero(maxTokens, kvBytesPerToken int64) bool {
	return maxTokens <= 0 && ClampRate(kvBytesPerToken) > 0
}

// AddByteCharge adds tokens*rate without wrapping. An overflowed
// pending charge must reject against every finite pool, so saturation at
// MaxInt64 is both conservative and sufficient for admission/capacity math.
func AddByteCharge(total, tokens, rate int64) int64 {
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

// Budget is a provider's reconstructed whole-box token budget,
// carried in token units always and additionally in byte units when every
// budget slot reports KVBytesPerToken (byteMode).
type Budget struct {
	// hasBudgetReport distinguishes an authoritative provider budget from the
	// zero value used by legacy providers. Engine V2 can truthfully report
	// ActiveTokenBudgetMax == 0 after its live fleet clamp while still reporting
	// KVBytesPerToken > 0; that means known-full, not "budget unavailable."
	Reported bool
	// used is Σ (ActiveTokenBudgetUsed + QueuedTokenBudget) across budget
	// slots — reservations the provider itself reports as live.
	Used int64
	// committed is the all-slots analog of committedTokenBudget: Σ per slot of
	// max(used+queued, MaxTokensPotential). It is the heartbeat-visible
	// commitment baseline subtracted from coordinator-pending tokens so
	// requests the provider already accounts for are not double-counted.
	Committed int64
	// total is the physical ceiling: the sum of the slots' private engine
	// grants (ActiveTokenBudgetMax).
	Total int64

	// usedBytes / committedBytes / totalBytes are the byte-normalized analogs
	// of used / committed / total: each slot's token quantities × that slot's
	// KVBytesPerToken. Only meaningful when byteMode is true.
	UsedBytes      int64
	CommittedBytes int64
	TotalBytes     int64
	// byteMode is true when there is at least one budget slot and EVERY budget
	// slot reports KVBytesPerToken > 0, i.e. the pool can be reconstructed in
	// bytes. False ⇒ pooledBudgetAdmits uses token accounting exactly.
	ByteMode bool
	// kvRates holds each budget slot's model and its reported (clamped)
	// per-token KV rate, for normalizing coordinator-pending charges into
	// bytes — a fixed inline table (a box serves a handful of co-resident
	// models) that spills to a heap slice only past pooledKVRateInline entries,
	// so reconstructing a pool once per provider per routing scan allocates
	// nothing (pooled_kv_rates.go). Read through kvRateFor; empty when no
	// budget slot reports a rate.
	rates RateTable
	// maxResidentKVBytesPerToken is the largest clamped rate among budget
	// slots. It can raise, but never lower, the conservative cold-model default.
	maxResidentKVBytesPerToken int64
}

// FromSlots reconstructs the provider's pooled budget from its
// backend slots. A legacy slot with neither a positive token budget nor a KV
// rate is ignored. A positive KV rate is retained even when the token budget is
// zero: Engine V2 uses that combination to report authoritative known-zero
// capacity after its live fleet clamp. Only positive maxima (private grants)
// add capacity; a known-zero slot's live use is still retained as a
// commitment after a grant shrink. Negative values are floored. A nil/empty or
// entirely legacy slice yields the unconstrained zero value.
func FromSlots(slots []protocol.BackendSlotCapacity) Budget {
	used, total := TokenTotals(slots)
	pool := Budget{Used: used, Total: total, ByteMode: true}
	reportedSlots := 0
	for _, slot := range slots {
		// Retain a reported rate before considering the token maximum. A v2
		// slot can have a known rate and an authoritative zero max; pending,
		// incoming, and capacity math must still agree on that model's rate.
		rate := ClampRate(slot.KVBytesPerToken)
		if slot.ActiveTokenBudgetMax <= 0 && rate <= 0 {
			// True legacy/unknown slot: neither field carries a constraint.
			continue
		}
		reportedSlots++
		if rate <= 0 {
			// A positive token budget without a KV rate keeps token-mode
			// accounting for the whole provider.
			pool.ByteMode = false
		} else {
			pool.rates.Set(slot.Model, rate)
			if rate > pool.maxResidentKVBytesPerToken {
				pool.maxResidentKVBytesPerToken = rate
			}
		}

		slotUsed := addNonnegativeSaturating(0, slot.ActiveTokenBudgetUsed)
		slotUsed = addNonnegativeSaturating(slotUsed, slot.QueuedTokenBudget)
		c := slotUsed
		if slot.MaxTokensPotential > c {
			c = slot.MaxTokensPotential
		}
		if c < 0 {
			c = 0
		}
		// A re-slice may shrink below an in-flight request's live use. Keep
		// that commitment in the de-dup baseline even when the new max is zero.
		pool.Committed = addNonnegativeSaturating(pool.Committed, c)
		if rate > 0 {
			// Live/committed use remains physical even when the current max is
			// zero. Saturation makes malformed reports fail closed.
			pool.UsedBytes = AddByteCharge(pool.UsedBytes, slotUsed, rate)
			pool.CommittedBytes = AddByteCharge(pool.CommittedBytes, c, rate)
			// totalBytes mirrors the token path's physical ceiling (Σ grants),
			// NOT committed+potential. committedBytes carries
			// MaxTokensPotential only as the pending de-dup baseline
			// (subtracted in pooledBudgetAdmits' extra); adding it into the
			// pool total too would double-count a slot's not-yet-materialized
			// future growth as extra physical KV capacity.
			pool.TotalBytes = addNonnegativeSaturating(
				pool.TotalBytes,
				AddByteCharge(0, slot.ActiveTokenBudgetMax, rate))
		}
	}
	pool.Reported = reportedSlots > 0
	if !pool.Reported {
		pool.ByteMode = false
	}
	return pool
}

// Snapshot combines a reconstructed budget with coordinator-pending work for
// admission and capacity publication. It never changes the underlying budget.
func Snapshot(pool *Budget, pendingTokens int, pendingBytes int64, pendingBytesKnown bool, modelRate int64) admission.PoolBudget {
	return admission.PoolBudget{
		Reported: pool.Reported, ByteMode: pool.ByteMode, PendingBytesKnown: pendingBytesKnown,
		Total: pool.Total, Used: pool.Used, Committed: pool.Committed, Pending: int64(pendingTokens),
		TotalBytes: pool.TotalBytes, UsedBytes: pool.UsedBytes,
		CommittedBytes: pool.CommittedBytes, PendingBytes: pendingBytes,
		Rate: ResolveRate(pool, modelRate),
	}
}

// RemainingTokens is the capacity-snapshot analog of pooledBudgetAdmits:
// how many tokens of a model whose per-token KV rate is modelRate still fit the
// box-wide pool once every model's coordinator-pending tokens are charged.
// pooledBudgetAdmits(snap, n) admits iff n <= pooledRemainingTokens(pool, …,
// snap.kvBytesPerToken) with the same inputs, so the public capacity feed
// (/v1/models[/capacity]) cannot advertise pooled headroom the admission gate
// refuses. Both branch identically: BYTES when the pool is byte-reconstructable
// (byteMode) and every pending charge normalized (pendingBytesKnown), pricing
// this model through resolvedPooledKVBytesPerToken — the same known/default
// policy pooledBudgetAdmits uses — so the two stay equivalent. Token accounting
// only when !byteMode or !pendingBytesKnown. Returns -1 when the provider
// reports no pooled budget (hasBudgetReport=false) — the "no pooled constraint"
// sentinel that leaves the per-slot numbers unclamped. An authoritative zero
// budget returns 0.
func RemainingTokens(pool Budget, pendingTokensAllModels int, pendingBytesAllModels int64, pendingBytesKnown bool, modelRate int64) int64 {
	return admission.PoolRemaining(Snapshot(&pool, pendingTokensAllModels,
		pendingBytesAllModels, pendingBytesKnown, modelRate))
}
