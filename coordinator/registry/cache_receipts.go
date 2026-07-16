package registry

import (
	"container/heap"
	"crypto/rand"
	"encoding/base64"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func newCacheReceiptNonce() (string, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(nonce[:]), nil
}

// PrepareCacheAttempt requests only protocol-v2 exact proof. Protocol-v0
// providers receive a unique encrypted-body buster; v0/v1 providers otherwise
// remain ordinary serving candidates without cache preference.
func (r *Registry) PrepareCacheAttempt(pr *PendingRequest, provider *Provider) error {
	if r == nil || pr == nil || provider == nil {
		return nil
	}
	r.ForgetCacheAttempt(pr)
	provider.mu.Lock()
	protocolVersion := provider.PrefixCacheProtocol
	provider.mu.Unlock()
	if protocolVersion < 1 {
		bust, err := newCacheReceiptNonce()
		if err != nil {
			return err
		}
		pr.LegacyCacheBustKey = "darkbloom-uncached-" + bust
		return nil
	}
	if protocolVersion < 2 || !pr.CachePlan.present() {
		return nil
	}
	return r.PreparePrefixCacheV2Attempt(pr, provider, pr.CachePlan)
}

func (r *Registry) ForgetCacheAttempt(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker != nil {
		tracker.forgetAttempt(pr.CacheReceiptNonce)
	}
	pr.CacheReceiptNonce = ""
	pr.CacheScope = ""
	pr.PrefixCacheProtocol = 0
	pr.LegacyCacheBustKey = ""
	pr.setCacheRoutingParticipates(false)
}

// V1 frames remain decodable during rollback, but never mutate exact routing
// evidence.
func (r *Registry) ApplyPrefixCacheLookup(string, *protocol.PrefixCacheLookupMessage) bool {
	return false
}

func (r *Registry) ApplyPrefixCacheReady(string, *protocol.PrefixCacheReadyMessage) bool {
	return false
}

func (t *cacheRoutingTracker) forgetAttempt(nonce string) {
	if t == nil || nonce == "" {
		return
	}
	t.mu.Lock()
	t.removeAttemptLocked(nonce)
	t.mu.Unlock()
}

func (t *cacheRoutingTracker) markAttemptTerminal(nonce string, now time.Time) {
	if t == nil || nonce == "" {
		return
	}
	t.mu.Lock()
	if attempt, ok := t.activeAttemptLocked(nonce, now); ok {
		attempt.ExpiresAt = now.Add(cacheRoutingAttemptTTL)
		t.attempts[nonce] = attempt
	}
	t.mu.Unlock()
}

func (r *Registry) MarkCacheAttemptTerminal(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker != nil {
		tracker.markAttemptTerminal(pr.CacheReceiptNonce, time.Now())
	}
}

func validCacheOutcome(outcome string) bool {
	switch outcome {
	case "hit", "miss_absent", "miss_corrupt", "skipped_capacity", "skipped_cost", "skipped_policy":
		return true
	default:
		return false
	}
}

func (t *cacheRoutingTracker) disconnect(providerID string) {
	if t == nil || providerID == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, holders := range t.holders {
		if _, exists := holders[providerID]; exists {
			t.removeHolderLocked(key, providerID)
		}
	}
	for nonce, attempt := range t.attempts {
		if attempt.ProviderID == providerID {
			t.removeAttemptLocked(nonce)
		}
	}
	for key := range t.v2Sequences {
		if key.ProviderID == providerID {
			delete(t.v2Sequences, key)
		}
	}
	for key := range t.rejectedV2 {
		if key.ProviderID == providerID {
			delete(t.rejectedV2, key)
		}
	}
}

func (t *cacheRoutingTracker) invalidateProviderModel(providerID, modelID string) {
	if t == nil || providerID == "" || modelID == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, holders := range t.holders {
		if holder, exists := holders[providerID]; exists && holder.ModelID == modelID {
			t.removeHolderLocked(key, providerID)
		}
	}
	for nonce, attempt := range t.attempts {
		if attempt.ProviderID == providerID && attempt.Model == modelID {
			t.removeAttemptLocked(nonce)
		}
	}
	for key := range t.v2Sequences {
		if key.ProviderID == providerID && key.ModelID == modelID {
			delete(t.v2Sequences, key)
		}
	}
}

func (t *cacheRoutingTracker) storeAttemptLocked(nonce string, attempt cacheAttempt) {
	t.attempts[nonce] = attempt
	if entry := t.attemptOrderByNonce[nonce]; entry != nil {
		entry.createdAt = attempt.CreatedAt
		heap.Fix(&t.attemptOrder, entry.index)
		return
	}
	entry := &cacheAttemptOrderEntry{nonce: nonce, createdAt: attempt.CreatedAt}
	heap.Push(&t.attemptOrder, entry)
	t.attemptOrderByNonce[nonce] = entry
}

func (t *cacheRoutingTracker) removeAttemptLocked(nonce string) {
	delete(t.attempts, nonce)
	if entry := t.attemptOrderByNonce[nonce]; entry != nil {
		heap.Remove(&t.attemptOrder, entry.index)
		delete(t.attemptOrderByNonce, nonce)
	}
}

func (t *cacheRoutingTracker) upsertHolderLocked(key string, holder cacheHolder) {
	if key == "" || holder.ProviderID == "" {
		return
	}
	holders := t.holders[key]
	if holders == nil {
		holders = make(map[string]cacheHolder)
		t.holders[key] = holders
	}
	if _, exists := holders[holder.ProviderID]; !exists {
		t.holderCount++
	}
	holders[holder.ProviderID] = holder
	t.trackHolderOrderLocked(key, holder.ProviderID, holder.UpdatedAt)
	if len(holders) > t.maxHolders {
		oldestProviderID := ""
		var oldestUpdatedAt time.Time
		for providerID, candidate := range holders {
			if oldestProviderID == "" || candidate.UpdatedAt.Before(oldestUpdatedAt) ||
				(candidate.UpdatedAt.Equal(oldestUpdatedAt) && providerID < oldestProviderID) {
				oldestProviderID = providerID
				oldestUpdatedAt = candidate.UpdatedAt
			}
		}
		t.removeHolderLocked(key, oldestProviderID)
	}
	t.enforceCapLocked()
}

func (t *cacheRoutingTracker) activeHolderLocked(
	key, providerID string,
	now time.Time,
) (cacheHolder, bool) {
	holder, exists := t.holders[key][providerID]
	if !exists {
		return cacheHolder{}, false
	}
	if now.Before(holder.ExpiresAt) {
		return holder, true
	}
	t.removeHolderLocked(key, providerID)
	return cacheHolder{}, false
}

func (t *cacheRoutingTracker) activeAttemptLocked(nonce string, now time.Time) (cacheAttempt, bool) {
	attempt, exists := t.attempts[nonce]
	if !exists {
		return cacheAttempt{}, false
	}
	if now.Before(attempt.ExpiresAt) {
		return attempt, true
	}
	t.removeAttemptLocked(nonce)
	return cacheAttempt{}, false
}

func (t *cacheRoutingTracker) trackHolderOrderLocked(
	key, providerID string,
	updatedAt time.Time,
) {
	ref := cacheHolderRef{key: key, providerID: providerID}
	if entry := t.holderOrderByRef[ref]; entry != nil {
		entry.updatedAt = updatedAt
		heap.Fix(&t.holderOrder, entry.index)
		return
	}
	entry := &cacheHolderOrderEntry{ref: ref, updatedAt: updatedAt}
	heap.Push(&t.holderOrder, entry)
	t.holderOrderByRef[ref] = entry
}

func (t *cacheRoutingTracker) removeHolderLocked(key, providerID string) {
	ref := cacheHolderRef{key: key, providerID: providerID}
	if holders := t.holders[key]; holders != nil {
		if _, exists := holders[providerID]; exists {
			delete(holders, providerID)
			t.holderCount--
		}
		if len(holders) == 0 {
			delete(t.holders, key)
		}
	}
	if entry := t.holderOrderByRef[ref]; entry != nil {
		heap.Remove(&t.holderOrder, entry.index)
		delete(t.holderOrderByRef, ref)
	}
}

func (t *cacheRoutingTracker) sweepLocked(now time.Time) {
	for key, holders := range t.holders {
		for providerID, holder := range holders {
			if !now.Before(holder.ExpiresAt) {
				t.removeHolderLocked(key, providerID)
			}
		}
	}
	for nonce, attempt := range t.attempts {
		if !now.Before(attempt.ExpiresAt) {
			t.removeAttemptLocked(nonce)
		}
	}
}

func (t *cacheRoutingTracker) sweepIfDueLocked(now time.Time) {
	if !t.lastSweep.IsZero() && now.Before(t.lastSweep.Add(cacheRoutingSweepInterval)) {
		return
	}
	t.sweepLocked(now)
	t.lastSweep = now
}

func (t *cacheRoutingTracker) enforceCapLocked() {
	for t.holderCount > t.maxEntries {
		t.removeHolderLocked(t.holderOrder[0].ref.key, t.holderOrder[0].ref.providerID)
	}
}

func (t *cacheRoutingTracker) enforceAttemptCapLocked() {
	for len(t.attempts) > t.maxAttempts {
		t.removeAttemptLocked(t.attemptOrder[0].nonce)
	}
}
