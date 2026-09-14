package admission

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/providerversion"
)

// pool.go — provider-level (all-models) token-budget admission.
//
// Provider versions through v0.7.4 report each slot's committed tokens plus the
// box's ONE shared live KV headroom. The per-slot admission check can therefore
// double-spend that shared pool across co-resident models inside the heartbeat
// gap. The v0.7.5 one-engine runtime instead re-slices the fleet KV budget into
// private per-engine grants; those slot maxima are additive, while each slot's
// own admission ceiling remains binding. The pooled check closes the legacy
// heartbeat gap and preserves the v0.7.5 aggregate capacity by reconstructing
// the layout appropriate for the provider version, with ALL models'
// coordinator-pending tokens counted. Providers that report neither a token
// budget nor a KV rate remain unconstrained; a modern slot with a positive KV
// rate and a zero budget is authoritative known-zero capacity and fails closed.
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

// Pool is a provider's reconstructed whole-box token budget,
// carried in token units always and additionally in byte units when every
// budget slot reports KVBytesPerToken (byteMode).
type Pool struct {
	// hasBudgetReport distinguishes an authoritative provider budget from the
	// zero value used by legacy providers. Engine V2 can truthfully report
	// ActiveTokenBudgetMax == 0 after its live fleet clamp while still reporting
	// KVBytesPerToken > 0; that means known-full, not "budget unavailable."
	hasBudgetReport bool
	// used is Σ (ActiveTokenBudgetUsed + QueuedTokenBudget) across budget
	// slots — reservations the provider itself reports as live.
	used int64
	// committed is the all-slots analog of CommittedTokenBudget: Σ per slot of
	// max(used+queued, MaxTokensPotential). It is the heartbeat-visible
	// commitment baseline subtracted from coordinator-pending tokens so
	// requests the provider already accounts for are not double-counted.
	committed int64
	// total is the layout-specific physical ceiling: live use plus one shared
	// free-headroom view through v0.7.4, or the sum of fixed private engine
	// grants for v0.7.5+.
	total int64

	// usedBytes / committedBytes / totalBytes are the byte-normalized analogs
	// of used / committed / total: each slot's token quantities × that slot's
	// KVBytesPerToken, using the same version-specific shared/private layout as
	// total. Only meaningful when byteMode is true.
	usedBytes      int64
	committedBytes int64
	totalBytes     int64
	// byteMode is true when there is at least one budget slot and EVERY budget
	// slot reports KVBytesPerToken > 0, i.e. the pool can be reconstructed in
	// bytes. False ⇒ PoolAdmits uses token accounting exactly.
	byteMode bool
	// kvRates holds each budget slot's model and its reported (clamped)
	// per-token KV rate, for normalizing coordinator-pending charges into
	// bytes — a fixed inline table (a box serves a handful of co-resident
	// models) that spills to a heap slice only past pooledKVRateInline entries,
	// so reconstructing a pool once per provider per routing scan allocates
	// nothing (kv_rates.go). Read through KVRateFor; empty when no
	// budget slot reports a rate.
	kvRates      [pooledKVRateInline]slotKVRate
	kvRateCount  int
	kvRatesSpill []slotKVRate
	// maxResidentKVBytesPerToken is the largest clamped rate among budget
	// slots. It can raise, but never lower, the conservative cold-model default.
	maxResidentKVBytesPerToken int64
}

// NewPool reconstructs the provider's pooled budget from its
// backend slots. A legacy slot with neither a positive token budget nor a KV
// rate is ignored. A positive KV rate is retained even when the token budget is
// zero: Engine V2 uses that combination to report authoritative known-zero
// capacity after its live fleet clamp. Only positive maxima add capacity; in
// the private layout, a known-zero slot's live use is still retained as a
// commitment after a grant shrink. Negative values are floored.
// A nil/empty or entirely legacy slice yields the unconstrained zero value.
func NewPool(slots []protocol.BackendSlotCapacity, layout providerversion.SlotBudgetLayout) Pool {
	used, total := TokenBudget(slots, layout)
	pool := Pool{used: used, total: total, byteMode: true}
	reportedSlots := 0
	var pooledFreeBytes int64
	var privateCapacityBytes int64
	for _, slot := range slots {
		// Retain a reported rate before considering the token maximum. A v2
		// slot can have a known rate and an authoritative zero max; pending,
		// incoming, and capacity math must still agree on that model's rate.
		rate := ClampKVBytesPerToken(slot.KVBytesPerToken)
		if slot.ActiveTokenBudgetMax <= 0 && rate <= 0 {
			// True legacy/unknown slot: neither field carries a constraint.
			continue
		}
		reportedSlots++
		if rate <= 0 {
			// A positive token budget without a KV rate keeps the exact legacy
			// token-mode behavior for the whole provider.
			pool.byteMode = false
		} else {
			pool.setKVRate(slot.Model, rate)
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
		if rate > 0 {
			// Live/committed use remains physical even when the current max is
			// zero. Saturation makes malformed reports fail closed.
			pool.usedBytes = AddByteCharge(pool.usedBytes, slotUsed, rate)
			pool.committedBytes = AddByteCharge(pool.committedBytes, c, rate)
			if layout == providerversion.PrivateSlotGrants {
				privateCapacityBytes = addNonnegativeSaturating(
					privateCapacityBytes,
					AddByteCharge(0, slot.ActiveTokenBudgetMax, rate))
			}
		}
		if layout == providerversion.PrivateSlotGrants {
			// A re-slice may shrink below an in-flight request's live use. Keep
			// that commitment in the de-dup baseline even when the new max is zero.
			pool.committed = addNonnegativeSaturating(pool.committed, c)
		}
		if slot.ActiveTokenBudgetMax <= 0 {
			// Known-zero contributes no new headroom.
			continue
		}
		if layout != providerversion.PrivateSlotGrants {
			pool.committed = addNonnegativeSaturating(pool.committed, c)
		}
		if rate <= 0 {
			continue
		}
		free := AddByteCharge(0, slot.ActiveTokenBudgetMax-slotUsed, rate)
		if layout != providerversion.PrivateSlotGrants && free > pooledFreeBytes {
			// v0.7.4 and older: every slot observes the same shared pool, so
			// count the largest live view exactly once.
			pooledFreeBytes = free
		}
	}
	pool.hasBudgetReport = reportedSlots > 0
	if !pool.hasBudgetReport {
		pool.byteMode = false
	}
	// totalBytes mirrors the token path's physical ceiling, NOT
	// committed+potential. Private layouts sum the fixed engine grants; legacy
	// layouts reconstruct live used + one shared-free view. committedBytes carries
	// MaxTokensPotential only as the pending de-dup baseline (subtracted in
	// PoolAdmits' extra); adding it into the pool total too would
	// double-count a co-resident slot's not-yet-materialized future growth as
	// extra physical KV capacity, letting an in-gap burst overcommit the box.
	if layout == providerversion.PrivateSlotGrants {
		pool.totalBytes = privateCapacityBytes
	} else {
		pool.totalBytes = addNonnegativeSaturating(pool.usedBytes, pooledFreeBytes)
	}
	return pool
}

// ByteMode reports whether every budget slot has a usable byte rate.
func (p *Pool) ByteMode() bool { return p.byteMode }

// TotalBytes returns the reconstructed byte ceiling (valid only in ByteMode).
func (p *Pool) TotalBytes() int64 { return p.totalBytes }
