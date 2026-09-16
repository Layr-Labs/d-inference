package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/cacheattempt"
)

type cacheRoutingGeneration = cacheattempt.Generation

// CacheAttemptSnapshot retains the public queued-frame API. Its owner keeps
// preparation and dispatch state independent of the mutable PendingRequest.
type CacheAttemptSnapshot = cacheattempt.Snapshot

func (pr *PendingRequest) CacheAttemptSnapshot() CacheAttemptSnapshot {
	if pr == nil {
		return CacheAttemptSnapshot{}
	}
	return pr.cacheAttempt.Snapshot()
}

func (pr *PendingRequest) beginCachePreparation() (ticket uint64, open bool) {
	return pr.cacheAttempt.Begin(func() { pr.LegacyCacheBustKey = "" })
}

func (pr *PendingRequest) publishCacheAttempt(ticket uint64, owner *cacheattempt.Attempt) bool {
	return pr.cacheAttempt.Publish(ticket, owner)
}

// Publication is a second generation/connection check after nonce creation and
// directory insertion. Retirement may have happened during either operation.
func (r *Registry) publishCacheAttempt(
	pr *PendingRequest, provider *Provider, revision, ticket uint64,
	tracker *cacheRoutingTracker, owner *cacheattempt.Attempt,
) bool {
	r.mu.RLock()
	published := false
	if r.cacheRoutingMode == CacheRoutingOn && r.cacheRouting == tracker &&
		r.providers[provider.ID] == provider {
		provider.mu.Lock()
		if provider.prefixCacheRevision == revision {
			published = pr.publishCacheAttempt(ticket, owner)
		}
		provider.mu.Unlock()
	}
	r.mu.RUnlock()
	if !published {
		owner.Forget()
	}
	return published
}

func (pr *PendingRequest) markCacheAttemptTerminal(now time.Time) {
	pr.cacheAttempt.Terminal(now)
}
