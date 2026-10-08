package memorypolicy

import (
	kvbudget "github.com/eigeninference/d-inference/coordinator/internal/registry/kvbudget"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

// PoolAdmits reports whether a request of requestTokens fits the
// provider's reconstructed whole-box pool once every model's coordinator-side
// pending tokens (snap.pendingMaxTokensAllModels / snap.pendingMaxBytesAllModels)
// are charged against it. The subtraction of the committed baseline mirrors the
// per-slot check's committedTokenBudget subtraction (avoid double-counting requests the
// heartbeat already reflects), floored at zero. hasBudgetReport=false means a
// legacy provider (or a snapshot built without backend capacity) reported no
// pooled constraint. An authoritative report whose total is zero is known-full.
//
// The check runs in BYTES when the pool is byte-reconstructable (byteMode) and
// every pending charge was normalizable (snap.pendingBytesKnown). The single
// kvbudget.ResolveRate policy prices both resident and cold/absent
// requests: own rates are preserved, a cold model may use its explicit forecast,
// and unknown rates retain the conservative default/largest-resident fallback.
// Token accounting is used only when the pool is not byte-reconstructable or
// the snapshot predates/omits byte accumulation.
func PoolAdmits(snap *Input, requestTokens int64) bool {
	return admission.PoolAdmits(kvbudget.Snapshot(&snap.PooledTokenBudget,
		snap.PendingMaxTokensAllModels, snap.PendingMaxBytesAllModels,
		snap.PendingBytesKnown, snap.requestKVBytesPerToken()), requestTokens)
}
