package admission

import (
	"math"
)

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

func addNonnegativeSaturating(total, value int64) int64 {
	if value <= 0 {
		return total
	}
	if total > math.MaxInt64-value {
		return math.MaxInt64
	}
	return total + value
}

// ClampKVBytesPerToken floors a per-token KV rate at 0 and caps it at
// maxKVBytesPerToken so byte-pool products cannot overflow. A negative rate is
// treated as absent (0), matching the pool's "no byte rate" handling.
func ClampKVBytesPerToken(r int64) int64 {
	if r < 0 {
		return 0
	}
	if r > maxKVBytesPerToken {
		return maxKVBytesPerToken
	}
	return r
}

// ResolvedKVBytesPerToken returns the byte rate used by every pooled-KV
// charge. A positive provider-reported model rate is clamped and preserved. A
// cold/unknown model on a byte-reconstructable pool is priced at the larger of
// the coordinator's conservative cold-model default and the largest resident
// rate. Resident rates alone cannot safely estimate a different model that has
// not loaded yet, while retaining a higher observed resident rate avoids
// weakening the fallback. Legacy/non-reconstructable pools return 0 and retain
// token accounting.
func ResolvedKVBytesPerToken(pool *Pool, reportedRate int64) int64 {
	if !pool.byteMode {
		return 0
	}
	if rate := ClampKVBytesPerToken(reportedRate); rate > 0 {
		return rate
	}
	rate := int64(DefaultKVBytesPerToken)
	if pool.maxResidentKVBytesPerToken > rate {
		rate = pool.maxResidentKVBytesPerToken
	}
	return ClampKVBytesPerToken(rate)
}

// KnownZeroTokenBudget distinguishes an authoritative zero from an omitted
// legacy budget. Engine V2 reports KVBytesPerToken whenever it knows the model's
// rate, including when its live fleet clamp leaves room for zero tokens. That
// model-local zero must bind even if a co-resident model still has pooled
// headroom.
func KnownZeroTokenBudget(maxTokens, kvBytesPerToken int64) bool {
	return maxTokens <= 0 && ClampKVBytesPerToken(kvBytesPerToken) > 0
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

// PoolAdmits reports whether a request of requestTokens fits the
// provider's reconstructed whole-box pool once every model's coordinator-side
// pending tokens (snap.pendingMaxTokensAllModels / snap.pendingMaxBytesAllModels)
// are charged against it. The subtraction of the committed baseline mirrors the
// per-slot check's CommittedTokenBudget subtraction (avoid double-counting requests the
// heartbeat already reflects), floored at zero. hasBudgetReport=false means a
// legacy provider (or a snapshot built without backend capacity) reported no
// pooled constraint. An authoritative report whose total is zero is known-full.
//
// The check runs in BYTES when the pool is byte-reconstructable (byteMode) and
// every pending charge was normalizable (snap.pendingBytesKnown). The single
// ResolvedKVBytesPerToken policy prices both resident and cold/absent
// requests: resident rates are preserved after clamping; cold unknown rates use
// at least the conservative default, never a cheap resident-only estimate.
// Token accounting is used only when the pool is not byte-reconstructable or
// the snapshot predates/omits byte accumulation.
func PoolAdmits(snap *Snapshot, requestTokens int64) bool {
	pool := &snap.Pool
	if !pool.hasBudgetReport {
		return true
	}
	if pool.total <= 0 {
		return requestTokens == 0
	}
	if pool.byteMode && snap.PendingBytesKnown {
		reqRate := ResolvedKVBytesPerToken(pool, snap.KVBytesPerToken)
		if reqRate > 0 {
			extra := snap.PendingMaxBytesAllModels - pool.committedBytes
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
	extra := int64(snap.PendingMaxTokensAllModels) - pool.committed
	if extra < 0 {
		extra = 0
	}
	remaining := pool.total - pool.used
	if remaining < 0 || extra > remaining || requestTokens < 0 {
		return false
	}
	return requestTokens <= remaining-extra
}

// RemainingTokens is the capacity-snapshot analog of PoolAdmits:
// how many tokens of a model whose per-token KV rate is modelRate still fit the
// shared pool once every model's coordinator-pending tokens are charged.
// PoolAdmits(snap, n) admits iff n <= RemainingTokens(pool, …,
// snap.kvBytesPerToken) with the same inputs, so the public capacity feed
// (/v1/models[/capacity]) cannot advertise pooled headroom the admission gate
// refuses. Both branch identically: BYTES when the pool is byte-reconstructable
// (byteMode) and every pending charge normalized (pendingBytesKnown), pricing
// this model through ResolvedKVBytesPerToken — the same known/default
// policy PoolAdmits uses — so the two stay equivalent. Token accounting
// only when !byteMode or !pendingBytesKnown. Returns -1 when the provider
// reports no pooled budget (hasBudgetReport=false) — the "no pooled constraint"
// sentinel that leaves the per-slot numbers unclamped. An authoritative zero
// budget returns 0.
func RemainingTokens(pool Pool, pendingTokensAllModels int, pendingBytesAllModels int64, pendingBytesKnown bool, modelRate int64) int64 {
	if !pool.hasBudgetReport {
		return -1
	}
	if pool.total <= 0 {
		return 0
	}
	if pool.byteMode && pendingBytesKnown {
		rate := ResolvedKVBytesPerToken(&pool, modelRate)
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
