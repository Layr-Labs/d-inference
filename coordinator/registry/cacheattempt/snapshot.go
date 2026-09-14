package cacheattempt

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Snapshot captures immutable receipt metadata for a queued frame. Validity
// and participation use atomics; it never consults a replacement attempt or
// mutable request dispatch fields.
type Snapshot struct{ owner *Attempt }

// Metadata returns the captured identity without accepting a frame or testing
// revocation. ApplyTo is the authoritative dispatch check.
func (snapshot Snapshot) Metadata() (Metadata, bool) {
	if snapshot.owner == nil {
		return Metadata{}, false
	}
	return snapshot.owner.metadata, true
}

// ApplyTo validates at writer dequeue, before JSON/socket IO. Revocation after
// this check may not retract an accepted write; revocation before it sends an
// ordinary uncached request. No registry or receipt lock is taken here.
func (snapshot Snapshot) ApplyTo(message *protocol.InferenceRequestMessage) {
	message.CacheReceiptNonce, message.CacheScope = "", ""
	message.PrefixCacheProtocol, message.CacheReceiptBoundaryMode = 0, ""
	owner := snapshot.owner
	if owner == nil {
		return
	}
	if owner.revoked.Load() || owner.generation.Revoked() {
		owner.dispatchState.CompareAndSwap(dispatchPrepared, dispatchCold)
		return
	}
	owner.dispatchState.Store(dispatchAccepted)
	message.CacheReceiptNonce, message.CacheScope = owner.metadata.Nonce, owner.metadata.Scope
	message.PrefixCacheProtocol, message.CacheReceiptBoundaryMode = 2, owner.metadata.BoundaryMode
}
