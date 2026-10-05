package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
)

func (t *Tracker[P]) StoreAttemptLocked(nonce string, attempt Attempt[P]) bool {
	if !t.generation.Active() {
		return false
	}
	charge, valid := CacheAttemptCharge(nonce, attempt)
	if !valid {
		return false
	}
	now := t.now()
	t.SweepIfDueLocked(now)
	old := t.attempts.Lookup(nonce).AccountedBytes
	total, fits := t.attemptBudget.replacementTotal(old, charge)
	if !fits && (total == 0 || charge > t.attemptBudget.MaxBytes()) {
		// Reclaiming cannot help an inconsistent or overflowing ledger, nor a
		// record larger than the whole budget.
		t.noteAttemptBudgetRefusalLocked()
		return false
	}
	key, owned, valid := detachCacheAttempt(nonce, attempt)
	if !valid || !t.generation.Active() {
		return false
	}
	// The complete candidate is validated and detached before any terminal
	// grace is given up for it.
	if !fits {
		total, fits = t.reclaimTerminalGraceLocked(now, nonce, total)
		if !fits {
			t.noteAttemptBudgetRefusalLocked()
			return false
		}
	}
	owned.Terminal = t.attempts.Lookup(nonce).Terminal
	owned.AccountedBytes = charge // Never trust a caller-supplied charge.
	t.attempts.Store(key, owned)
	t.attemptBudget.Store(total)
	if entry := t.attemptOrder.Load(nonce); entry != nil {
		if entry.Key().ProviderID != attempt.ProviderID {
			t.UnindexAttemptLocked(entry)
			t.attemptOrder.Track(nonce, cacheindex.AttemptRef{Nonce: entry.Key().Nonce, ProviderID: owned.ProviderID}, attempt.ExpiresAt)
			t.IndexAttemptLocked(entry)
		} else {
			t.attemptOrder.Track(nonce, entry.Key(), attempt.ExpiresAt)
		}
		if t.terminalOrder.Load(nonce) != nil {
			t.terminalOrder.Track(nonce, entry.Key(), attempt.ExpiresAt)
		}
		return true
	}
	entry := t.attemptOrder.Track(key, cacheindex.AttemptRef{Nonce: key, ProviderID: owned.ProviderID}, owned.ExpiresAt)
	t.IndexAttemptLocked(entry)
	return true
}

func (t *Tracker[P]) RemoveAttemptLocked(nonce string) {
	if attempt, exists := t.attempts.Load(nonce); exists {
		t.attemptBudget.refund(attempt.AccountedBytes)
	}
	t.attempts.Delete(nonce)
	t.terminalOrder.Remove(nonce)
	if entry := t.attemptOrder.Remove(nonce); entry != nil {
		t.UnindexAttemptLocked(entry)
	}
}

func (t *Tracker[P]) UpsertHolderLocked(key string, holder Holder[P]) {
	if key == "" || holder.ProviderID == "" || !t.generation.Active() {
		return
	}
	holders := t.holders.Bucket(key)
	if inserted := t.holders.Store(cacheindex.HolderRef{Key: key, ProviderID: holder.ProviderID}, holder); inserted {
		t.holderAdded++
	}
	t.TrackHolderOrderLocked(key, holder.ProviderID, holder.ExpiresAt)
	t.PersistHolderUpsert(key, holder)
	// Every receipt stamps UpdatedAt with the tracker clock it was applied at.
	now := holder.UpdatedAt
	if holders.Count() > t.maxHolders {
		oldestProviderID := ""
		var oldestUpdatedAt time.Time
		for providerID, candidate := range holders.Entries() {
			if oldestProviderID == "" || candidate.UpdatedAt.Before(oldestUpdatedAt) ||
				(candidate.UpdatedAt.Equal(oldestUpdatedAt) && providerID < oldestProviderID) {
				oldestProviderID = providerID
				oldestUpdatedAt = candidate.UpdatedAt
			}
		}
		// A bucket holds one tier, so its oldest update is also its first
		// expiry. Resident holders live as long as the sweep interval, so an
		// expired victim the sweep has not reached yet is common.
		t.RemoveHolderLocked(key, oldestProviderID,
			CacheCapRemovalReason(holders.Lookup(oldestProviderID).ExpiresAt, now))
	}
	t.EnforceCapLocked(now)
}

func (t *Tracker[P]) ActiveHolderLocked(
	key, providerID string,
	now time.Time,
) (Holder[P], bool) {
	holder, exists := t.holders.Bucket(key).Load(providerID)
	if !exists {
		return Holder[P]{}, false
	}
	if now.Before(holder.ExpiresAt) {
		return holder, true
	}
	t.RemoveHolderLocked(key, providerID, cacheHolderRemovalTTL)
	return Holder[P]{}, false
}

func (t *Tracker[P]) ActiveAttemptLocked(nonce string, now time.Time) (Attempt[P], bool) {
	if !t.generation.Active() {
		return Attempt[P]{}, false
	}
	attempt, exists := t.attempts.Load(nonce)
	if !exists {
		return Attempt[P]{}, false
	}
	if now.Before(attempt.ExpiresAt) {
		return attempt, true
	}
	t.RemoveAttemptLocked(nonce)
	return Attempt[P]{}, false
}

// A refresh re-keys the existing entry in place: heap.Fix moves it to the
// position of its new expiry, in either direction.
func (t *Tracker[P]) TrackHolderOrderLocked(
	key, providerID string,
	expiresAt time.Time,
) {
	ref := cacheindex.HolderRef{Key: key, ProviderID: providerID}
	if entry := t.holderOrder.Load(ref); entry != nil {
		t.holderOrder.Track(ref, ref, expiresAt)
		return
	}
	entry := t.holderOrder.Track(ref, ref, expiresAt)
	t.IndexHolderLocked(entry)
}

func (t *Tracker[P]) RemoveHolderLocked(
	key, providerID string,
	reason RemovalReason,
) {
	ref := cacheindex.HolderRef{Key: key, ProviderID: providerID}
	if removed, exists := t.holders.Load(ref); exists {
		// A disconnect keeps the durable row: the file is still on the
		// provider and its epoch identifies it again on reconnect.
		t.PersistHolderRemoval(key, removed, reason)
		t.holders.Delete(ref)
		t.holderRemoved[string(reason)]++
	}
	if entry := t.holderOrder.Remove(ref); entry != nil {
		t.UnindexHolderLocked(entry)
	}
}
