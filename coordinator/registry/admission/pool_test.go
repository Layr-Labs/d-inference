package admission

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestProviderPooledTokenBudgetClampsKVByteRate is the overflow regression: a
// slot reporting an absurd (unbounded) KVBytesPerToken multiplied by a normal
// token count wraps int64 to a NEGATIVE usedBytes/totalBytes, which breaks the
// byte-pool admission (a negative total either rejects everything or, with a
// negative left side, admits everything). The clamp caps the rate at
// maxKVBytesPerToken so all products and sums stay positive and admission fails
// closed. Fails without ClampKVBytesPerToken in providerPooledTokenBudget.
func TestProviderPooledTokenBudgetClampsKVByteRate(t *testing.T) {
	const normalMax = 400_000
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: normalMax, ActiveTokenBudgetUsed: 200_000, KVBytesPerToken: math.MaxInt64 / 2},
	}
	pool := legacyPool(slots)
	if !pool.byteMode {
		t.Fatal("byteMode = false with a (clamped) positive KV rate")
	}
	if pool.usedBytes < 0 || pool.committedBytes < 0 || pool.totalBytes < 0 {
		t.Fatalf("byte pool overflowed to negative: used=%d committed=%d total=%d (KV rate not clamped)",
			pool.usedBytes, pool.committedBytes, pool.totalBytes)
	}
	if pool.totalBytes < pool.usedBytes {
		t.Fatalf("totalBytes %d < usedBytes %d (overflow)", pool.totalBytes, pool.usedBytes)
	}
	if got := pool.KVRateFor("a"); got != maxKVBytesPerToken {
		t.Fatalf("stored KV rate = %d, want clamp %d (raw absurd rate not clamped)", got, maxKVBytesPerToken)
	}
	// Admission must fail-closed for a request that overflows the pool, not
	// admit-everything off a wrapped negative total. Free headroom is
	// (400k − 200k) = 200k tokens at the clamped rate.
	snap := Snapshot{
		ActiveTokenBudgetMax: normalMax,
		KVBytesPerToken:      maxKVBytesPerToken,
		PendingBytesKnown:    true,
		Pool:                 pool,
	}
	if PoolAdmits(snapPtr(snap), 10_000_000_000) {
		t.Fatal("admitted a 10B-token request into a finite byte pool (overflow admitted-everything)")
	}
	if !PoolAdmits(snapPtr(snap), 100_000) {
		t.Fatal("rejected a 100k-token request that fits the 200k-token byte headroom")
	}
}

// TestPooledKnownZeroBudgetRejects distinguishes a modern Engine V2 slot whose
// positive KV rate makes a zero budget authoritative from a legacy slot that
// reports neither field. A live fleet clamp can truthfully drive the v2 token
// budget to zero while KVBytesPerToken remains known; treating total==0 as the
// legacy "no constraint" sentinel would fail open.
func TestPooledKnownZeroBudgetRejects(t *testing.T) {
	pool := legacyPool([]protocol.BackendSlotCapacity{
		{Model: "known-full", ActiveTokenBudgetMax: 0, KVBytesPerToken: 800_000},
	})
	snap := Snapshot{
		KVBytesPerToken:   800_000,
		PendingBytesKnown: true,
		Pool:              pool,
	}
	if PoolAdmits(snapPtr(snap), 1) {
		t.Fatal("known-zero Engine V2 budget admitted a request as if it were an unconstrained legacy slot")
	}
	if got := RemainingTokens(pool, 0, 0, true, 800_000); got != 0 {
		t.Fatalf("known-zero pooled remaining = %d, want 0", got)
	}

	legacy := legacyPool([]protocol.BackendSlotCapacity{{Model: "legacy"}})
	legacySnap := Snapshot{Pool: legacy}
	if !PoolAdmits(snapPtr(legacySnap), 1) {
		t.Fatal("legacy slot with no budget or KV rate became constrained")
	}
	if got := RemainingTokens(legacy, 0, 0, false, 0); got != -1 {
		t.Fatalf("legacy pooled remaining = %d, want -1 no-constraint sentinel", got)
	}
}

func TestProviderPooledTokenBudget(t *testing.T) {
	cases := []struct {
		name      string
		slots     []protocol.BackendSlotCapacity
		used      int64
		committed int64
		total     int64
	}{
		{name: "nil_slots"},
		{
			name: "single_slot",
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 10_000, ActiveTokenBudgetUsed: 1_000, QueuedTokenBudget: 500, MaxTokensPotential: 3_000},
			},
			used:      1_500,
			committed: 3_000, // potential dominates used+queued
			total:     10_000,
		},
		{
			name: "two_slots_shared_headroom_counted_once",
			// Both slots see the same 8k shared free headroom:
			// maxA = 2k committed + 8k, maxB = 1k committed + 8k.
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 10_000, ActiveTokenBudgetUsed: 2_000},
				{Model: "b", ActiveTokenBudgetMax: 9_000, ActiveTokenBudgetUsed: 1_000},
			},
			used:      3_000,
			committed: 3_000,
			total:     11_000, // 3k committed + 8k shared free ONCE (not 19k)
		},
		{
			name: "budgetless_slot_ignored_negatives_floored",
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 10_000, ActiveTokenBudgetUsed: -50, MaxTokensPotential: -10},
				{Model: "legacy", ActiveTokenBudgetMax: 0, ActiveTokenBudgetUsed: 5_000},
			},
			used:      0,
			committed: 0,
			total:     10_000,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := legacyPool(tc.slots)
			if got.used != tc.used || got.committed != tc.committed || got.total != tc.total {
				t.Fatalf("providerPooledTokenBudget = %+v, want {used:%d committed:%d total:%d}",
					got, tc.used, tc.committed, tc.total)
			}
		})
	}
}

func TestPrivateGrantPoolUsesCeilingsWhenLiveUseExceedsReslice(t *testing.T) {
	const rate int64 = 100_000
	tests := []struct {
		name       string
		slots      []protocol.BackendSlotCapacity
		wantUsed   int64
		wantTotal  int64
		wantRemain int64
	}{
		{
			name: "shrunken slot remains over its new ceiling",
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 5_000, ActiveTokenBudgetUsed: 8_000, KVBytesPerToken: rate},
				{Model: "b", ActiveTokenBudgetMax: 5_000, KVBytesPerToken: rate},
			},
			wantUsed:   8_000,
			wantTotal:  10_000,
			wantRemain: 2_000,
		},
		{
			name: "known-zero slot live use drains a co-resident grant",
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 0, ActiveTokenBudgetUsed: 3_000, KVBytesPerToken: rate},
				{Model: "b", ActiveTokenBudgetMax: 5_000, KVBytesPerToken: rate},
			},
			wantUsed:   3_000,
			wantTotal:  5_000,
			wantRemain: 2_000,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			pool := versionedPool(tc.slots, "0.7.5")
			if pool.used != tc.wantUsed || pool.total != tc.wantTotal {
				t.Fatalf("token pool = {used:%d total:%d}, want {%d %d}",
					pool.used, pool.total, tc.wantUsed, tc.wantTotal)
			}
			if pool.usedBytes != tc.wantUsed*rate || pool.totalBytes != tc.wantTotal*rate {
				t.Fatalf("byte pool = {used:%d total:%d}, want {%d %d}",
					pool.usedBytes, pool.totalBytes, tc.wantUsed*rate, tc.wantTotal*rate)
			}
			if got := RemainingTokens(pool, 0, 0, true, rate); got != tc.wantRemain {
				t.Fatalf("remaining = %d, want %d", got, tc.wantRemain)
			}
			snap := Snapshot{
				KVBytesPerToken:   rate,
				PendingBytesKnown: true,
				Pool:              pool,
			}
			if !PoolAdmits(snapPtr(snap), tc.wantRemain) {
				t.Fatalf("rejected exact remaining capacity %d", tc.wantRemain)
			}
			if PoolAdmits(snapPtr(snap), tc.wantRemain+1) {
				t.Fatalf("admitted past remaining capacity %d", tc.wantRemain)
			}
		})
	}
}

func TestPrivateGrantPoolSaturatesUsedBudgetAddition(t *testing.T) {
	pool := versionedPool([]protocol.BackendSlotCapacity{{
		Model:                 "overflow",
		ActiveTokenBudgetMax:  math.MaxInt64,
		ActiveTokenBudgetUsed: math.MaxInt64,
		QueuedTokenBudget:     1,
		KVBytesPerToken:       1,
	}}, "0.7.5")
	if pool.used != math.MaxInt64 || pool.usedBytes != math.MaxInt64 {
		t.Fatalf("overflowed used budget = {tokens:%d bytes:%d}, want saturated MaxInt64",
			pool.used, pool.usedBytes)
	}
	if PoolAdmits(snapPtr(Snapshot{
		KVBytesPerToken:   1,
		PendingBytesKnown: true,
		Pool:              pool,
	}),

		1) {
		t.Fatal("overflowed live use left invented private-grant headroom")
	}
}

// TestFreeMemoryAdmitsSingleModelUnchanged pins that the pooled check is
// arithmetically inert for single-model providers: for one budget slot the
// pool reduces to that slot's own budget and the admission boundary is
// byte-for-byte the old per-slot one — including the case where
// MaxTokensPotential dominates used+queued in the committed baseline.
func TestFreeMemoryAdmitsSingleModelUnchanged(t *testing.T) {
	slot := protocol.BackendSlotCapacity{
		Model:                 "m",
		ActiveTokenBudgetMax:  10_000,
		ActiveTokenBudgetUsed: 3_000,
		QueuedTokenBudget:     500,
		MaxTokensPotential:    6_000,
	}
	// Old per-slot formula: used+queued + max(0, pending − max(used+queued,
	// potential)) + req ≤ max → 3_500 + 1_000 + req ≤ 10_000 → req ≤ 5_500.
	mkSnap := func(pending int) Snapshot {
		return Snapshot{
			PendingMaxTokens:          pending,
			PendingMaxTokensAllModels: pending, // single model: identical
			ActiveTokenBudgetUsed:     slot.ActiveTokenBudgetUsed,
			ActiveTokenBudgetMax:      slot.ActiveTokenBudgetMax,
			QueuedTokenBudget:         slot.QueuedTokenBudget,
			MaxTokensPotential:        slot.MaxTokensPotential,
			Pool:                      legacyPool([]protocol.BackendSlotCapacity{slot}),
		}
	}
	if !testPolicy.FreeMemoryAdmits(snapPtr(mkSnap(7_000)), 0, 5_500) {
		t.Fatal("request at the exact old boundary (5_500) rejected — pooled check changed single-model behavior")
	}
	if testPolicy.FreeMemoryAdmits(snapPtr(mkSnap(7_000)), 0, 5_501) {
		t.Fatal("request past the old boundary (5_501) admitted — budget admission loosened")
	}
}

// TestFreeMemoryAdmitsPooledRejectsGapDoubleSpend is the pure-function version
// of the double-spend regression (fails without the PoolAdmits call):
// model B's own slot budget admits, but the all-models pending has consumed
// the pool.
func TestFreeMemoryAdmitsPooledRejectsGapDoubleSpend(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000},
		{Model: "b", ActiveTokenBudgetMax: 10_000},
	}
	snap := Snapshot{
		// Snapshot for model B: no same-model pending, stale heartbeat (used 0).
		PendingMaxTokens:          0,
		PendingMaxTokensAllModels: 10_000, // model A's in-gap burst
		ActiveTokenBudgetMax:      10_000,
		Pool:                      legacyPool(slots),
	}
	if testPolicy.FreeMemoryAdmits(snapPtr(snap), 100, 1_900) {
		t.Fatal("admitted 2k tokens into a pool with 10k already pending to a co-resident model (per-slot double-spend)")
	}
	// Same snapshot with only 4k pending across models → admits.
	snap.PendingMaxTokensAllModels = 4_000
	if !testPolicy.FreeMemoryAdmits(snapPtr(snap), 100, 1_900) {
		t.Fatal("rejected 2k tokens although the pool has 6k of headroom")
	}
}

// TestProviderPooledTokenBudgetByteNormalization pins the byte-space
// reconstruction: per-slot token quantities scale by that slot's own
// KVBytesPerToken, the shared free headroom is the largest per-slot free BYTE
// view counted once, and a single budget slot without a KV rate disables byte
// mode for the whole pool (legacy provider build).
func TestProviderPooledTokenBudgetByteNormalization(t *testing.T) {
	// Big-KV model A: 10k tokens × 100kB/token headroom = 1 GB.
	// Small-KV model B: 100k tokens × 10kB/token = the SAME 1 GB pool.
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "b", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	}
	pool := legacyPool(slots)
	if !pool.byteMode {
		t.Fatal("byteMode = false with every budget slot reporting a KV rate")
	}
	if pool.totalBytes != 1_000_000_000 || pool.usedBytes != 0 || pool.committedBytes != 0 {
		t.Fatalf("byte pool = {used:%d committed:%d total:%d}, want {0 0 1e9} (shared free bytes counted once)",
			pool.usedBytes, pool.committedBytes, pool.totalBytes)
	}
	// Token space is denominated by the LARGEST free-token view (B's 100k) —
	// the very distortion byte mode exists to correct.
	if pool.total != 100_000 {
		t.Fatalf("token pool total = %d, want 100_000", pool.total)
	}

	// One budget slot without a rate → byte reconstruction impossible.
	mixed := legacyPool([]protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "legacy", ActiveTokenBudgetMax: 9_000},
	})
	if mixed.byteMode {
		t.Fatal("byteMode = true although a budget slot reports no KVBytesPerToken")
	}
}

// TestFreeMemoryAdmitsByteNormalizedHeterogeneousKV is the X-unit regression:
// co-resident slots with different KVBytesPerToken share ONE byte pool, so
// token counts are not a common unit. A 90k-token pending burst on the
// small-KV model (10 kB/token = 0.9 GB) leaves only 0.1 GB of the 1 GB pool,
// so a 3k-token request to the big-KV model (100 kB/token = 0.3 GB) must be
// rejected — token accounting (93k ≤ 100k) would admit it and the box OOMs.
// Fails without the byte-normalized branch in PoolAdmits.
func TestFreeMemoryAdmitsByteNormalizedHeterogeneousKV(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	}
	mkSnap := func(pendingSmallKVTokens int64) Snapshot {
		return Snapshot{
			// Snapshot for the big-KV model: no same-model pending, stale
			// heartbeat (used 0), all pending is the small-KV burst.
			ActiveTokenBudgetMax:      10_000,
			KVBytesPerToken:           100_000,
			PendingMaxTokensAllModels: int(pendingSmallKVTokens),
			PendingMaxBytesAllModels:  pendingSmallKVTokens * 10_000,
			PendingBytesKnown:         true,
			Pool:                      legacyPool(slots),
		}
	}
	// 90k small-KV tokens pending = 0.9 GB; +0.3 GB request = 1.2 GB > 1 GB.
	if testPolicy.FreeMemoryAdmits(snapPtr(mkSnap(90_000)), 100, 2_900) {
		t.Fatal("admitted 0.3 GB of big-KV request into a byte pool with 0.9 GB already pending (token/byte unit confusion)")
	}
	// Control: 40k small-KV tokens pending = 0.4 GB; +0.3 GB = 0.7 GB ≤ 1 GB.
	if !testPolicy.FreeMemoryAdmits(snapPtr(mkSnap(40_000)), 100, 2_900) {
		t.Fatal("rejected a request although the byte pool has 0.6 GB of headroom (byte gate over-rejecting)")
	}
}

// TestFreeMemoryAdmitsByteModeCorrectsTokenOverReject is the reverse sanity
// case: when heartbeat skew leaves the token pool denominated by a SMALLER
// free view than the true byte pool, token accounting over-rejects small-KV
// work that genuinely fits in bytes. With the fix the byte check admits;
// without it the token check (61k > 50k) wrongly rejects.
func TestFreeMemoryAdmitsByteModeCorrectsTokenOverReject(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		// Big-KV slot sees 1 GB free (10k × 100 kB); small-KV slot's staler
		// view reports only 0.5 GB (50k × 10 kB). Token total = max(10k, 50k)
		// = 50k tokens; byte total = max(1 GB, 0.5 GB) = 1 GB.
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "small-kv", ActiveTokenBudgetMax: 50_000, KVBytesPerToken: 10_000},
	}
	snap := Snapshot{
		// Snapshot for the small-KV model with a 60k-token (0.6 GB) small-KV
		// burst pending elsewhere on the box and a 1k-token (10 MB) request.
		ActiveTokenBudgetMax:      50_000,
		KVBytesPerToken:           10_000,
		PendingMaxTokensAllModels: 60_000,
		PendingMaxBytesAllModels:  600_000_000,
		PendingBytesKnown:         true,
		Pool:                      legacyPool(slots),
	}
	if !PoolAdmits(snapPtr(snap), 1_000) {
		t.Fatal("rejected 10 MB into a 1 GB byte pool holding 0.6 GB (token-unit over-rejection not corrected)")
	}
}

// TestFreeMemoryAdmitsColdModelChargesPool is the cold-slot pooled-gate
// regression (pure-function form): the target model reports NO budget slot
// (activeTokenBudgetMax == 0, not loaded here), so it skips the budget branch
// entirely — but a resident co-model's slot reports the shared pool, and the
// in-gap pending burst has already consumed it. The cold request must be
// charged against the pool too, or it double-spends the same KV the resident
// pending will occupy. Fails without the cold-path PoolAdmits call.
func TestFreeMemoryAdmitsColdModelChargesPool(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "resident", ActiveTokenBudgetMax: 10_000},
	}
	mkSnap := func(pendingAllModels int) Snapshot {
		return Snapshot{
			// Snapshot for a COLD model: no slot, no budget, model not loaded.
			PendingMaxTokensAllModels: pendingAllModels,
			Pool:                      legacyPool(slots),
		}
	}
	if testPolicy.FreeMemoryAdmits(snapPtr(mkSnap(10_000)), 100, 1_900) {
		t.Fatal("cold request admitted into a pool fully pending to a resident model (cold path skipped the pooled gate)")
	}
	// Control: with 4k of the 10k pool pending, the 2k cold request fits.
	if !testPolicy.FreeMemoryAdmits(snapPtr(mkSnap(4_000)), 100, 1_900) {
		t.Fatal("cold request rejected although the pool has 6k of headroom")
	}
}

// TestPooledByteTotalFromLiveUsedNotCommitted is the double-count regression
// (Finding 3): the byte pool total must be built from LIVE used bytes plus the
// shared free headroom — mirroring the token path (TokenBudget uses
// used+sharedFree) — NOT from committedBytes, which carries MaxTokensPotential
// as the pending de-dup baseline. A co-resident slot whose potential (0.4 GB)
// far exceeds its used (0) would otherwise inflate the 1 GB physical pool to
// 1.4 GB, letting an in-gap burst overcommit the box's real KV. Fails without
// the pool.usedBytes+sharedFreeBytes total in providerPooledTokenBudget.
func TestPooledByteTotalFromLiveUsedNotCommitted(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		// Big-KV slot with an active request whose POTENTIAL growth (4k tokens =
		// 0.4 GB) dwarfs its live used (0). Shared free = 10k × 100 kB = 1 GB.
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000, MaxTokensPotential: 4_000},
		// Small-KV co-resident sees the SAME 1 GB pool (100k × 10 kB).
		{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	}
	pool := legacyPool(slots)
	if !pool.byteMode {
		t.Fatal("byteMode = false with every budget slot reporting a KV rate")
	}
	if pool.usedBytes != 0 {
		t.Fatalf("usedBytes = %d, want 0 (no live used/queued on either slot)", pool.usedBytes)
	}
	if pool.committedBytes != 400_000_000 {
		t.Fatalf("committedBytes = %d, want 4e8 (0.4 GB de-dup baseline from MaxTokensPotential)", pool.committedBytes)
	}
	if pool.totalBytes != 1_000_000_000 {
		t.Fatalf("totalBytes = %d, want 1e9 (live used + shared free); committed potential must NOT inflate the pool total", pool.totalBytes)
	}

	// The admission gate must charge against the 1 GB physical pool, not the
	// inflated 1.4 GB. A 12k-token big-KV request is 1.2 GB — slot A's 0.4 GB of
	// potential is a de-dup baseline, not spare capacity, so it must be rejected.
	snap := Snapshot{
		ActiveTokenBudgetMax:      10_000,
		KVBytesPerToken:           100_000,
		PendingMaxBytesAllModels:  0,
		PendingMaxTokensAllModels: 0,
		PendingBytesKnown:         true,
		Pool:                      pool,
	}
	if PoolAdmits(snapPtr(snap), 12_000) {
		t.Fatal("admitted 1.2 GB into a 1 GB byte pool — MaxTokensPotential double-counted as physical KV capacity")
	}
	// Control: 8k tokens = 0.8 GB genuinely fits the 1 GB pool.
	if !PoolAdmits(snapPtr(snap), 8_000) {
		t.Fatal("rejected 0.8 GB that fits the 1 GB byte pool (byte total under-counted)")
	}
}

// TestPooledColdUnknownKVChargedInBytes is the cold unknown-KV regression: on a
// byte-reconstructable mixed-KV box, a COLD request (its own model has no
// resident slot, so snap.kvBytesPerToken == 0) must be priced CONSERVATIVELY in
// bytes at the bounded unknown-model default, NOT collapse to token accounting
// or borrow a rate that only describes resident models.
func TestPooledColdUnknownKVChargedInBytes(t *testing.T) {
	t.Run("mixed_kv_cold_priced_at_default_rate", func(t *testing.T) {
		slots := []protocol.BackendSlotCapacity{
			{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},   // 1 GB view
			{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000}, // same 1 GB
		}
		pool := legacyPool(slots)
		if !pool.byteMode {
			t.Fatal("pool byteMode = false, want true")
		}
		if got := ResolvedKVBytesPerToken(poolPtr(pool), 0); got != DefaultKVBytesPerToken {
			t.Fatalf("resolved cold KV rate = %d, want conservative default %d", got, DefaultKVBytesPerToken)
		}
		cold := Snapshot{
			KVBytesPerToken:   0, // cold/absent slot
			PendingBytesKnown: true,
			Pool:              pool,
		}
		// 50k tokens: token fallback would admit (50k <= 100k token pool), but
		// conservative byte pricing is far beyond the 1 GB pool.
		if PoolAdmits(snapPtr(cold), 50_000) {
			t.Fatal("cold unknown-KV request admitted via token/resident-rate fallback")
		}
		// Control: 2k tokens at the default rate remain below 1 GB.
		if !PoolAdmits(snapPtr(cold), 2_000) {
			t.Fatal("cold request rejected although its conservative byte charge fits the pool")
		}
		wantRemaining := pool.totalBytes / DefaultKVBytesPerToken
		if rem := RemainingTokens(pool, 0, 0, true, 0); rem != wantRemaining {
			t.Fatalf("cold pooledRemainingTokens = %d, want %d (byte pool / default rate)", rem, wantRemaining)
		}
	})

	// A known resident model still uses its reported rate, so its established
	// byte/token boundary is unchanged by the cold-model default.
	t.Run("known_model_keeps_reported_rate_boundary", func(t *testing.T) {
		pool := legacyPool([]protocol.BackendSlotCapacity{
			{Model: "m", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 50_000},
		})
		known := Snapshot{KVBytesPerToken: 50_000, PendingBytesKnown: true, Pool: pool}
		if !PoolAdmits(snapPtr(known), 10_000) {
			t.Fatal("known request at the exact 10k boundary rejected")
		}
		if PoolAdmits(snapPtr(known), 10_001) {
			t.Fatal("known request past the 10k boundary admitted")
		}
	})
}

// TestPooledFirstColdRequestUsesConservativeDefault pins the unknown-model
// boundary: resident slots only reveal THEIR KV rates, so the largest resident
// rate is not a safe price for a first request to a cold model. A box with only
// a cheap 10 kB/token resident model has a 1 GB pool; a 3k-token cold request
// fits at that resident rate but exceeds the pool at the bounded conservative
// default used for an unknown model.
func TestPooledFirstColdRequestUsesConservativeDefault(t *testing.T) {
	pool := legacyPool([]protocol.BackendSlotCapacity{
		{Model: "resident-small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	})
	snap := Snapshot{
		KVBytesPerToken:   0, // first request: cold model has no slot-reported rate
		PendingBytesKnown: true,
		Pool:              pool,
	}

	if PoolAdmits(snapPtr(snap), 3_000) {
		t.Fatal("first cold request priced at resident-only KV max instead of the conservative unknown-model default")
	}
	wantRemaining := pool.totalBytes / DefaultKVBytesPerToken
	if got := RemainingTokens(pool, 0, 0, true, 0); got != wantRemaining {
		t.Fatalf("cold pooled remaining = %d, want %d from conservative default rate", got, wantRemaining)
	}
}

// TestPooledRemainingTokensMatchesAdmits pins the equivalence the capacity feed
// relies on: PoolAdmits(snap, n) admits IFF n <= RemainingTokens(
// pool, …, snap.kvBytesPerToken), across the byte path (known rate), the byte
// COLD path (rate 0 -> bounded default substitution), token mode, and the
// pending-unknown fall-through. Both must apply the SAME rate resolver.
func TestPooledRemainingTokensMatchesAdmits(t *testing.T) {
	bytePool := legacyPool([]protocol.BackendSlotCapacity{
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	})
	tokenPool := legacyPool([]protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000},
		{Model: "b", ActiveTokenBudgetMax: 10_000},
	})
	cases := []struct {
		name string
		snap Snapshot
	}{
		{"byte_known_rate", Snapshot{
			KVBytesPerToken: 100_000, PendingBytesKnown: true,
			PendingMaxTokensAllModels: 20_000, PendingMaxBytesAllModels: 20_000 * 10_000,
			Pool: bytePool,
		}},
		{"byte_cold_rate", Snapshot{
			KVBytesPerToken: 0, PendingBytesKnown: true,
			PendingMaxTokensAllModels: 10_000, PendingMaxBytesAllModels: 10_000 * 10_000,
			Pool: bytePool,
		}},
		{"token_mode", Snapshot{
			PendingMaxTokensAllModels: 4_000,
			Pool:                      tokenPool,
		}},
		{"byte_pending_unknown_falls_to_token", Snapshot{
			KVBytesPerToken: 100_000, PendingBytesKnown: false,
			PendingMaxTokensAllModels: 5_000,
			Pool:                      bytePool,
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rem := RemainingTokens(
				tc.snap.Pool,
				tc.snap.PendingMaxTokensAllModels,
				tc.snap.PendingMaxBytesAllModels,
				tc.snap.PendingBytesKnown,
				tc.snap.KVBytesPerToken,
			)
			for n := int64(1); n <= rem+50; n++ {
				if admits, want := PoolAdmits(snapPtr(tc.snap), n), n <= rem; admits != want {
					t.Fatalf("n=%d: pooledBudgetAdmits=%v, but (n<=rem=%d)=%v", n, admits, rem, want)
				}
			}
		})
	}
}

// TestFreeMemoryAdmitsLegacyProviderUnchanged: providers that report no token
// budget (ActiveTokenBudgetMax == 0) never reach the budget branch — the
// legacy memory-estimation path is untouched by the pooled fields.
func TestFreeMemoryAdmitsLegacyProviderUnchanged(t *testing.T) {
	snap := Snapshot{
		ModelLoaded:               true,
		TotalMemoryGB:             64,
		GPUMemoryActiveGB:         10,
		ModelSizeGB:               14,
		PendingMaxTokensAllModels: 1 << 30, // must be ignored on the legacy path
	}
	if !testPolicy.FreeMemoryAdmits(snapPtr(snap), 100, 1_900) {
		t.Fatal("legacy (budget-less) admission changed: loaded model with free memory must admit")
	}
}
