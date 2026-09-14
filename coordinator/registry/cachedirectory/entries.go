package cachedirectory

import (
	"container/heap"
	"time"
)

func (t *Directory[C]) ForgetCacheAttempt(nonce string) {
	if t == nil || nonce == "" {
		return
	}
	t.mu.Lock()
	t.removeAttemptLocked(nonce)
	t.mu.Unlock()
}

func (t *Directory[C]) MarkCacheAttemptTerminal(nonce string, now time.Time) {
	if t == nil || nonce == "" {
		return
	}
	t.mu.Lock()
	if attempt, ok := t.activeAttemptLocked(nonce, now); ok {
		attempt.ExpiresAt = now.Add(AttemptTTL)
		t.attempts[nonce] = attempt
	}
	t.mu.Unlock()
}

func validCacheOutcome(outcome string) bool {
	switch outcome {
	case "hit", "miss_absent", "miss_corrupt", "skipped_capacity", "skipped_cost", "skipped_policy":
		return true
	default:
		return false
	}
}

func (t *Directory[C]) storeAttemptLocked(nonce string, attempt Attempt[C]) {
	if t.generation.Revoked() {
		return
	}
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

func (t *Directory[C]) removeAttemptLocked(nonce string) {
	delete(t.attempts, nonce)
	if entry := t.attemptOrderByNonce[nonce]; entry != nil {
		heap.Remove(&t.attemptOrder, entry.index)
		delete(t.attemptOrderByNonce, nonce)
	}
}

func (t *Directory[C]) upsertHolderLocked(key string, holder Holder[C]) {
	if key == "" || holder.ProviderID == "" || t.generation.Revoked() {
		return
	}
	holders := t.holders[key]
	if holders == nil {
		holders = make(map[string]Holder[C])
		t.holders[key] = holders
	}
	if _, exists := holders[holder.ProviderID]; !exists {
		t.holderCount++
		t.holderAdded++
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
		t.removeHolderLocked(key, oldestProviderID, RemovalCapacityEviction)
	}
	t.enforceCapLocked()
}

func (t *Directory[C]) activeHolderLocked(
	key, providerID string,
	now time.Time,
) (Holder[C], bool) {
	holder, exists := t.holders[key][providerID]
	if !exists {
		return Holder[C]{}, false
	}
	if now.Before(holder.ExpiresAt) {
		return holder, true
	}
	t.removeHolderLocked(key, providerID, RemovalTTL)
	return Holder[C]{}, false
}

func (t *Directory[C]) activeAttemptLocked(nonce string, now time.Time) (Attempt[C], bool) {
	if t.generation.Revoked() {
		return Attempt[C]{}, false
	}
	attempt, exists := t.attempts[nonce]
	if !exists {
		return Attempt[C]{}, false
	}
	if now.Before(attempt.ExpiresAt) {
		return attempt, true
	}
	t.removeAttemptLocked(nonce)
	return Attempt[C]{}, false
}

func (t *Directory[C]) trackHolderOrderLocked(
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

func (t *Directory[C]) removeHolderLocked(
	key, providerID string,
	reason RemovalReason,
) {
	ref := cacheHolderRef{key: key, providerID: providerID}
	if holders := t.holders[key]; holders != nil {
		if _, exists := holders[providerID]; exists {
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
	}
}

func (t *Directory[C]) sweepLocked(now time.Time) {
	for key, holders := range t.holders {
		for providerID, holder := range holders {
			if !now.Before(holder.ExpiresAt) {
				t.removeHolderLocked(key, providerID, RemovalTTL)
			}
		}
	}
	for nonce, attempt := range t.attempts {
		if !now.Before(attempt.ExpiresAt) {
			t.removeAttemptLocked(nonce)
		}
	}
}

func (t *Directory[C]) sweepIfDueLocked(now time.Time) {
	if !t.lastSweep.IsZero() && now.Before(t.lastSweep.Add(SweepInterval)) {
		return
	}
	t.sweepLocked(now)
	t.lastSweep = now
}

func (t *Directory[C]) enforceCapLocked() {
	for t.holderCount > t.maxEntries {
		t.removeHolderLocked(
			t.holderOrder[0].ref.key,
			t.holderOrder[0].ref.providerID,
			RemovalCapacityEviction)
	}
}

func (t *Directory[C]) enforceAttemptCapLocked() {
	for len(t.attempts) > t.maxAttempts {
		t.removeAttemptLocked(t.attemptOrder[0].nonce)
	}
}
