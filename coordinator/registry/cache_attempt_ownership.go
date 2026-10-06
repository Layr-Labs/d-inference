package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheattempt"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
)

// A generation contains no prompt data or tracker maps. Plans may outlive a
// configuration change without retaining the retired generation's evidence.
type cacheRoutingGeneration = cacheplan.Generation

type cacheAttemptOwner = cacheattempt.Owner

type cacheReceiptRetention struct{ tracker *cacheRoutingTracker }

func (r cacheReceiptRetention) Forget(nonce string) { r.tracker.forgetAttempt(nonce) }
func (r cacheReceiptRetention) Terminal(nonce string) {
	r.tracker.markAttemptTerminal(nonce, r.tracker.now())
}

func newCacheAttemptOwner(tracker *cacheRoutingTracker, generation cacheattempt.Gate, nonce, scope, boundaryMode string, repeated, firstSight int) *cacheAttemptOwner {
	return cacheattempt.New(cacheattempt.Metadata{Nonce: nonce, Scope: scope, BoundaryMode: boundaryMode, RepeatedPrefixTokens: repeated, FirstSightTokens: firstSight}, generation, cacheReceiptRetention{tracker: tracker})
}

// CacheAttemptSnapshot captures immutable receipt metadata for a queued frame.
// Validity and participation use atomics; a snapshot never consults a replacement
// attempt or the PendingRequest's mutable dispatch fields.
type CacheAttemptSnapshot = cacheattempt.Snapshot

func (pr *PendingRequest) CacheAttemptSnapshot() CacheAttemptSnapshot {
	if pr == nil {
		return CacheAttemptSnapshot{}
	}
	return pr.cachePreparation.Snapshot()
}

// beginCachePreparation also invalidates an earlier preparation ticket. Tracker
// cleanup happens after the request lock is released.
func (pr *PendingRequest) beginCachePreparation() (ticket cacheattempt.Ticket, open bool) {
	pr.cacheAttemptMu.Lock()
	ticket, open, retirement := pr.cachePreparation.Begin()
	pr.LegacyCacheBustKey = ""
	pr.cacheAttemptMu.Unlock()
	retirement.Complete()
	return ticket, open
}

func (pr *PendingRequest) publishCacheAttempt(ticket cacheattempt.Ticket, owner *cacheAttemptOwner) bool {
	pr.cacheAttemptMu.Lock()
	defer pr.cacheAttemptMu.Unlock()
	return pr.cachePreparation.Publish(ticket, owner)
}

// CachePublisher commits staged metadata only after revalidating its captured
// generation and connection. A producer may delay publication, but must retain
// this operation rather than reconstructing ownership from a mutable request.
type CachePublisher interface{ Publish() bool }

type CachePublication struct {
	registry *Registry
	request  *PendingRequest
	provider *Provider
	revision cachepeer.Token
	ticket   cacheattempt.Ticket
	owner    *cacheAttemptOwner
	tracker  *cacheRoutingTracker
}

// Publish is a second generation/connection check after nonce creation and
// tracker insertion. Retirement may have happened during either operation.
func (publication CachePublication) Publish() bool {
	r, pr, provider := publication.registry, publication.request, publication.provider
	tracker, owner := publication.tracker, publication.owner
	r.mu.RLock()
	published := false
	if r.cacheRoutingMode == CacheRoutingOn && r.cacheRouting == tracker &&
		r.providers[provider.ID] == provider {
		provider.mu.Lock()
		if provider.prefixCacheRevision.Accepts(publication.revision) {
			published = pr.publishCacheAttempt(publication.ticket, owner)
		}
		provider.mu.Unlock()
	}
	r.mu.RUnlock()
	if !published {
		owner.ForgetReceipt()
	}
	return published
}

// The terminal timestamp comes from the owning tracker's clock so the
// shortened attempt TTL agrees with receipt and sweep time.
func (pr *PendingRequest) markCacheAttemptTerminal() {
	pr.cacheAttemptMu.Lock()
	retirement := pr.cachePreparation.Close()
	pr.cacheAttemptMu.Unlock()
	retirement.Complete()
}

// Configure revokes under r.mu, then drains these maps under their own lock.
// Old receipt/prepare calls cannot repopulate a retired tracker.
func (t *cacheRoutingTracker) clearRetired() {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.core.ClearRetired()
	if t.demand != nil {
		t.demand.clear()
	}
}
