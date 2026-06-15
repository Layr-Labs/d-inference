package registry

import (
	"sync"
	"time"
)

const (
	cacheAffinityTTL            = 10 * time.Minute
	defaultCacheAffinityBonusMs = 1_500.0
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
	mu      sync.Mutex
	ttl     time.Duration
	entries map[cacheAffinityKey]cacheAffinityEntry
}

func newCacheAffinityTracker(ttl time.Duration) *cacheAffinityTracker {
	if ttl <= 0 {
		ttl = cacheAffinityTTL
	}
	return &cacheAffinityTracker{ttl: ttl, entries: make(map[cacheAffinityKey]cacheAffinityEntry)}
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
	t.entries[cacheAffinityKey{account: account, model: model, scope: scope}] = cacheAffinityEntry{
		providerID: providerID,
		expiresAt:  now.Add(t.ttl),
	}
}

func (r *Registry) RecordCacheAffinity(account, model, scope, providerID string) {
	if r == nil || r.cacheAffinity == nil {
		return
	}
	r.cacheAffinity.record(account, model, scope, providerID, time.Now())
}
