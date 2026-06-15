package registry

import (
	"sync"
	"time"
)

const (
	cacheAffinityTTL            = 10 * time.Minute
	defaultCacheAffinityBonusMs = 1_500.0
	cacheAffinityMaxEntries     = 10_000
)

type cacheAffinityKey struct {
	account string
	model   string
	scope   string
}

type cacheAffinityEntry struct {
	providerID string
	expiresAt  time.Time
}

type cacheAffinityTracker struct {
	mu         sync.Mutex
	ttl        time.Duration
	maxEntries int
	entries    map[cacheAffinityKey]cacheAffinityEntry
}

func newCacheAffinityTracker(ttl time.Duration) *cacheAffinityTracker {
	if ttl <= 0 {
		ttl = cacheAffinityTTL
	}
	return &cacheAffinityTracker{ttl: ttl, maxEntries: cacheAffinityMaxEntries, entries: make(map[cacheAffinityKey]cacheAffinityEntry)}
}

func (t *cacheAffinityTracker) lookup(account, model, scope string, now time.Time) string {
	if t == nil || account == "" || model == "" || scope == "" {
		return ""
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	key := cacheAffinityKey{account: account, model: model, scope: scope}
	entry, ok := t.entries[key]
	if !ok {
		return ""
	}
	if now.After(entry.expiresAt) {
		delete(t.entries, key)
		return ""
	}
	return entry.providerID
}

func (t *cacheAffinityTracker) record(account, model, scope, providerID string, now time.Time) {
	if t == nil || account == "" || model == "" || scope == "" || providerID == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.entries) >= t.maxEntries {
		t.sweepExpiredLocked(now)
	}
	if len(t.entries) >= t.maxEntries {
		for key := range t.entries {
			delete(t.entries, key)
			break
		}
	}
	t.entries[cacheAffinityKey{account: account, model: model, scope: scope}] = cacheAffinityEntry{
		providerID: providerID,
		expiresAt:  now.Add(t.ttl),
	}
}

func (t *cacheAffinityTracker) sweepExpiredLocked(now time.Time) {
	for key, entry := range t.entries {
		if now.After(entry.expiresAt) {
			delete(t.entries, key)
		}
	}
}

func (r *Registry) RecordCacheAffinity(account, model, scope, providerID string) {
	if r == nil || r.cacheAffinity == nil {
		return
	}
	r.cacheAffinity.record(account, model, scope, providerID, time.Now())
}
