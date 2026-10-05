package preload

import (
	"slices"
	"time"
)

// PreloadActiveSetState is a detached view of the attempt state a later
// reconciliation may clear: the exact key, the outstanding operation and the
// failed batch whose retry is delayed. The policy's owner reads it before
// reconciling to decide whether that delay still binds the resulting key.
type PreloadActiveSetState struct {
	Key               PreloadSelectionSnapshot
	InflightOperation uint64 // Zero when no attempt is outstanding.
	FailedResult      bool   // The last completed batch left a desired member unacknowledged.
	BatchRetryKey     PreloadSelectionSnapshot
	BatchRetryAt      time.Duration
}

// State is the policy's current attempt state.
func (p *PreloadActiveSet) State() PreloadActiveSetState {
	state := PreloadActiveSetState{
		Key: p.Snapshot(), FailedResult: p.failedResult,
		BatchRetryKey: p.batchRetryKey.detached(), BatchRetryAt: p.batchRetryAt,
	}
	if p.inflight != nil {
		state.InflightOperation = p.inflight.Operation
	}
	return state
}

// CarryBatchRetry rebinds a completed failed batch's original deadline to the
// current key. Reconcile drops that deadline whenever the key changes; the
// owner restores it only while the native batch itself is unchanged, so the
// deadline is neither reset nor extended.
func (p *PreloadActiveSet) CarryBatchRetry(at time.Duration) {
	p.batchRetryKey, p.batchRetryAt = p.Snapshot(), at
	p.failedResult = true
}

// HoldsVerified reports whether the current key is this catalog generation's
// exact verified set, without detaching a snapshot.
func (p *PreloadActiveSet) HoldsVerified(generation uint64, verified []VerifiedPreloadArtifact) bool {
	return p.key.CatalogGeneration == generation && slices.Equal(p.key.Verified, verified)
}
