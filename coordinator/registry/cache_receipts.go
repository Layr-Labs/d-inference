package registry

import (
	"container/heap"
	"crypto/rand"
	"encoding/base64"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	legacyCacheBustPrefix = "darkbloom-uncached-"
	// LegacyCacheBustKeyLength is stable because newCacheReceiptNonce encodes
	// exactly 16 random bytes as 22-byte unpadded base64url.
	LegacyCacheBustKeyLength = len(legacyCacheBustPrefix) + 22
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
	provider.mu.Lock()
	protocolVersion := provider.PrefixCacheProtocol
	provider.mu.Unlock()
	if protocolVersion >= 2 && pr.CachePlan.present() {
		return r.PreparePrefixCacheV2Attempt(pr, provider, pr.CachePlan)
	}
	ticket, open := pr.beginCachePreparation()
	if !open {
		return nil
	}
	if protocolVersion < 1 {
		bust, err := newCacheReceiptNonce()
		if err != nil {
			return err
		}
		pr.cacheAttemptMu.Lock()
		if pr.cachePreparationTicket == ticket && !pr.cachePreparationClosed {
			pr.LegacyCacheBustKey = legacyCacheBustPrefix + bust
		}
		pr.cacheAttemptMu.Unlock()
		return nil
	}
	return nil
}

func (r *Registry) ForgetCacheAttempt(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	pr.beginCachePreparation()
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
		// Through the store so the expiry heap moves with the new deadline.
		attempt.ExpiresAt = now.Add(cacheRoutingAttemptTTL)
		t.storeAttemptLocked(nonce, attempt)
	}
	t.mu.Unlock()
}

func (r *Registry) MarkCacheAttemptTerminal(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	pr.markCacheAttemptTerminal()
}

func validCacheOutcome(outcome string) bool {
	switch outcome {
	case "hit", "miss_absent", "miss_corrupt", "skipped_capacity", "skipped_cost", "skipped_policy":
		return true
	default:
		return false
	}
}

func (t *cacheRoutingTracker) disconnect(providerID string, reason cacheHolderRemovalReason) {
	t.invalidateProviderEvidence(providerID, reason, false)
}

func (t *cacheRoutingTracker) invalidateProviderEvidence(providerID string, reason cacheHolderRemovalReason, preserveFences bool) {
	if t == nil || providerID == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	// Removal deletes from the set being ranged, which Go permits.
	for entry := range t.holdersByProvider[providerID] {
		t.removeHolderLocked(entry.ref.key, providerID, reason)
	}
	for entry := range t.attemptsByProvider[providerID] {
		t.removeAttemptLocked(entry.nonce)
	}
	for key := range t.v2Sequences {
		if key.ProviderID == providerID {
			delete(t.v2Sequences, key)
		}
	}
	if preserveFences {
		return
	}
	now := t.now()
	for key, fence := range t.rejectedV2 {
		if key.ProviderID == providerID {
			t.forgetFenceLocked(key, fence, now)
		}
	}
}

func (t *cacheRoutingTracker) invalidateProviderModel(providerID, modelID string, reason cacheHolderRemovalReason) {
	t.invalidateProviderModels(providerID, map[string]cacheHolderRemovalReason{modelID: reason})
}

// Visit this provider's entries once even when a heartbeat changes several
// models. Keep exact-capability proof fences: an unrelated update cannot
// reset quarantine.
func (t *cacheRoutingTracker) invalidateProviderModels(providerID string, models map[string]cacheHolderRemovalReason) {
	if t == nil || providerID == "" || len(models) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for entry := range t.holdersByProvider[providerID] {
		if holder, ok := t.holders[entry.ref.key][providerID]; ok {
			if reason, changed := models[holder.ModelID]; changed {
				t.removeHolderLocked(entry.ref.key, providerID, reason)
			}
		}
	}
	for entry := range t.attemptsByProvider[providerID] {
		if _, changed := models[t.attempts[entry.nonce].Model]; changed {
			t.removeAttemptLocked(entry.nonce)
		}
	}
	for key := range t.v2Sequences {
		if _, changed := models[key.ModelID]; key.ProviderID == providerID && changed {
			delete(t.v2Sequences, key)
		}
	}
}

func (t *cacheRoutingTracker) storeAttemptLocked(nonce string, attempt cacheAttempt) {
	if t.generation.revoked.Load() {
		return
	}
	t.attempts[nonce] = attempt
	if entry := t.attemptOrderByNonce[nonce]; entry != nil {
		if entry.providerID != attempt.ProviderID {
			t.unindexAttemptLocked(entry)
			entry.providerID = attempt.ProviderID
			t.indexAttemptLocked(entry)
		}
		entry.expiresAt = attempt.ExpiresAt
		heap.Fix(&t.attemptOrder, entry.index)
		return
	}
	entry := &cacheAttemptOrderEntry{nonce: nonce, providerID: attempt.ProviderID, expiresAt: attempt.ExpiresAt}
	heap.Push(&t.attemptOrder, entry)
	t.attemptOrderByNonce[nonce] = entry
	t.indexAttemptLocked(entry)
}

func (t *cacheRoutingTracker) removeAttemptLocked(nonce string) {
	delete(t.attempts, nonce)
	if entry := t.attemptOrderByNonce[nonce]; entry != nil {
		heap.Remove(&t.attemptOrder, entry.index)
		delete(t.attemptOrderByNonce, nonce)
		t.unindexAttemptLocked(entry)
	}
}

func (t *cacheRoutingTracker) upsertHolderLocked(key string, holder cacheHolder) {
	if key == "" || holder.ProviderID == "" || t.generation.revoked.Load() {
		return
	}
	holders := t.holders[key]
	if holders == nil {
		holders = make(map[string]cacheHolder)
		t.holders[key] = holders
	}
	if _, exists := holders[holder.ProviderID]; !exists {
		t.holderCount++
		t.holderAdded++
	}
	holders[holder.ProviderID] = holder
	t.trackHolderOrderLocked(key, holder.ProviderID, holder.ExpiresAt)
	if !t.restoring {
		t.persister.markHolderUpsert(key, holder)
	}
	// Every receipt stamps UpdatedAt with the tracker clock it was applied at.
	now := holder.UpdatedAt
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
		// A bucket holds one tier, so its oldest update is also its first
		// expiry. Resident holders live as long as the sweep interval, so an
		// expired victim the sweep has not reached yet is common.
		t.removeHolderLocked(key, oldestProviderID,
			cacheCapRemovalReason(holders[oldestProviderID].ExpiresAt, now))
	}
	t.enforceCapLocked(now)
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
	t.removeHolderLocked(key, providerID, cacheHolderRemovalTTL)
	return cacheHolder{}, false
}

func (t *cacheRoutingTracker) activeAttemptLocked(nonce string, now time.Time) (cacheAttempt, bool) {
	if t.generation.revoked.Load() {
		return cacheAttempt{}, false
	}
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

// A refresh re-keys the existing entry in place: heap.Fix moves it to the
// position of its new expiry, in either direction.
func (t *cacheRoutingTracker) trackHolderOrderLocked(
	key, providerID string,
	expiresAt time.Time,
) {
	ref := cacheHolderRef{key: key, providerID: providerID}
	if entry := t.holderOrderByRef[ref]; entry != nil {
		entry.expiresAt = expiresAt
		heap.Fix(&t.holderOrder, entry.index)
		return
	}
	entry := &cacheHolderOrderEntry{ref: ref, expiresAt: expiresAt}
	heap.Push(&t.holderOrder, entry)
	t.holderOrderByRef[ref] = entry
	t.indexHolderLocked(entry)
}

func (t *cacheRoutingTracker) removeHolderLocked(
	key, providerID string,
	reason cacheHolderRemovalReason,
) {
	ref := cacheHolderRef{key: key, providerID: providerID}
	if holders := t.holders[key]; holders != nil {
		if removed, exists := holders[providerID]; exists {
			// A disconnect keeps the durable row: the file is still on the
			// provider and its epoch identifies it again on reconnect.
			if reason == cacheHolderRemovalDisconnect {
				t.persister.parkHolder(key, removed)
			} else {
				t.persister.markHolderDelete(key, removed)
			}
			delete(holders, providerID)
			t.holderCount--
			t.holderRemoved[string(reason)]++
		}
		if len(holders) == 0 {
			delete(t.holders, key)
		}
	}
	if entry := t.holderOrderByRef[ref]; entry != nil {
		heap.Remove(&t.holderOrder, entry.index)
		delete(t.holderOrderByRef, ref)
		t.unindexHolderLocked(entry)
	}
}
