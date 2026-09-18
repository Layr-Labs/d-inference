package registry

import (
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A generation contains no prompt data or tracker maps. Plans may outlive a
// configuration change without retaining the retired generation's evidence.
type cacheRoutingGeneration struct{ revoked atomic.Bool }

const (
	cacheDispatchPrepared uint32 = iota
	cacheDispatchAccepted
	cacheDispatchCold
)

type cacheAttemptOwner struct {
	tracker       *cacheRoutingTracker
	generation    *cacheRoutingGeneration
	nonce         string
	scope         string
	boundaryMode  string
	revoked       atomic.Bool
	dispatchState atomic.Uint32
}

// CacheAttemptSnapshot captures immutable receipt metadata for a queued frame.
// Validity and participation use atomics; a snapshot never consults a replacement
// attempt or the PendingRequest's mutable dispatch fields.
type CacheAttemptSnapshot struct{ owner *cacheAttemptOwner }

func (pr *PendingRequest) CacheAttemptSnapshot() CacheAttemptSnapshot {
	if pr == nil {
		return CacheAttemptSnapshot{}
	}
	return CacheAttemptSnapshot{owner: pr.cacheAttempt.Load()}
}

// ApplyTo validates at writer dequeue, before JSON/socket IO. Revocation after
// this check may not retract an accepted write; revocation before it sends an
// ordinary uncached request. No registry or tracker lock is taken here.
func (snapshot CacheAttemptSnapshot) ApplyTo(message *protocol.InferenceRequestMessage) {
	message.CacheReceiptNonce, message.CacheScope = "", ""
	message.PrefixCacheProtocol, message.CacheReceiptBoundaryMode = 0, ""
	owner := snapshot.owner
	if owner == nil {
		return
	}
	if owner.revoked.Load() || owner.generation.revoked.Load() {
		owner.dispatchState.CompareAndSwap(cacheDispatchPrepared, cacheDispatchCold)
		return
	}
	owner.dispatchState.Store(cacheDispatchAccepted)
	message.CacheReceiptNonce, message.CacheScope = owner.nonce, owner.scope
	message.PrefixCacheProtocol, message.CacheReceiptBoundaryMode = 2, owner.boundaryMode
}

// beginCachePreparation also invalidates an earlier preparation ticket. Tracker
// cleanup happens after the request lock is released.
func (pr *PendingRequest) beginCachePreparation() (ticket uint64, open bool) {
	pr.cacheAttemptMu.Lock()
	owner := pr.cacheAttempt.Swap(nil)
	if owner != nil {
		owner.revoked.Store(true)
	}
	pr.cachePreparationTicket++
	ticket, open = pr.cachePreparationTicket, !pr.cachePreparationClosed
	pr.LegacyCacheBustKey = ""
	pr.cacheAttemptMu.Unlock()
	if owner != nil {
		owner.tracker.forgetAttempt(owner.nonce)
	}
	return ticket, open
}

func (pr *PendingRequest) publishCacheAttempt(ticket uint64, owner *cacheAttemptOwner) bool {
	pr.cacheAttemptMu.Lock()
	defer pr.cacheAttemptMu.Unlock()
	if pr.cachePreparationClosed || pr.cachePreparationTicket != ticket {
		return false
	}
	pr.cacheAttempt.Store(owner)
	return true
}

// Publication is a second generation/connection check after nonce creation and
// tracker insertion. Retirement may have happened during either operation.
func (r *Registry) publishCacheAttempt(
	pr *PendingRequest, provider *Provider, revision, ticket uint64, owner *cacheAttemptOwner,
) bool {
	r.mu.RLock()
	published := false
	if r.cacheRoutingMode == CacheRoutingOn && r.cacheRouting == owner.tracker &&
		r.providers[provider.ID] == provider {
		provider.mu.Lock()
		if provider.prefixCacheRevision == revision {
			published = pr.publishCacheAttempt(ticket, owner)
		}
		provider.mu.Unlock()
	}
	r.mu.RUnlock()
	if !published {
		owner.tracker.forgetAttempt(owner.nonce)
	}
	return published
}

func (pr *PendingRequest) markCacheAttemptTerminal(now time.Time) {
	pr.cacheAttemptMu.Lock()
	pr.cachePreparationClosed = true
	pr.cachePreparationTicket++
	owner := pr.cacheAttempt.Load()
	if owner != nil {
		owner.revoked.Store(true)
	}
	pr.cacheAttemptMu.Unlock()
	if owner != nil {
		owner.tracker.markAttemptTerminal(owner.nonce, now)
	}
}

// Configure revokes under r.mu, then drains these maps under their own lock.
// Old receipt/prepare calls cannot repopulate a retired tracker.
func (t *cacheRoutingTracker) clearRetired() {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.holders, t.attempts = nil, nil
	t.holderOrder, t.attemptOrder = nil, nil
	t.holderOrderByRef, t.attemptOrderByNonce = nil, nil
	t.v2Sequences, t.rejectedV2 = nil, nil
	t.holderCount = 0
}
