package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
)

const AttemptTTL = 2 * time.Minute

func (t *Tracker[P]) MarkAttemptTerminal(nonce string, now time.Time) {
	if attempt, ok := t.ActiveAttemptLocked(nonce, now); ok {
		// Through the store so the expiry heap moves with the new deadline.
		attempt.ExpiresAt = now.Add(AttemptTTL)
		t.StoreAttemptLocked(nonce, attempt)
	}
}

func (t *Tracker[P]) InvalidateProviderEvidence(providerID string, reason RemovalReason, preserveFences bool) {
	// Removal deletes from the set being ranged, which Go permits.
	for entry := range t.holdersByProvider.Entries(providerID) {
		t.RemoveHolderLocked(entry.Key().Key, providerID, reason)
	}
	for entry := range t.attemptsByProvider.Entries(providerID) {
		t.RemoveAttemptLocked(entry.Key().Nonce)
	}
	for key := range t.v2Sequences.Entries() {
		if key.ProviderID == providerID {
			t.v2Sequences.Delete(key)
		}
	}
	if preserveFences {
		return
	}
	now := t.now()
	t.proofs.ForgetProvider(providerID, now)
}

// Visit this provider's entries once even when a heartbeat changes several
// models. Keep exact-capability proof fences: an unrelated update cannot
// reset quarantine.
func (t *Tracker[P]) InvalidateProviderModels(providerID string, models map[string]RemovalReason) {
	for entry := range t.holdersByProvider.Entries(providerID) {
		if holder, ok := t.holders.Bucket(entry.Key().Key).Load(providerID); ok {
			if reason, changed := models[holder.ModelID]; changed {
				t.RemoveHolderLocked(entry.Key().Key, providerID, reason)
			}
		}
	}
	for entry := range t.attemptsByProvider.Entries(providerID) {
		if _, changed := models[t.attempts.Lookup(entry.Key().Nonce).Model]; changed {
			t.RemoveAttemptLocked(entry.Key().Nonce)
		}
	}
	for key := range t.v2Sequences.Entries() {
		if _, changed := models[key.ModelID]; key.ProviderID == providerID && changed {
			t.v2Sequences.Delete(key)
		}
	}
}

// InvalidateProviderPlan drops one provider's holders at the boundaries the
// mismatched plan named, in both tiers: a chain divergence is a tokenization
// disagreement on that prompt, not a tier property. Sequence watermarks and
// other prompts' holders on the same model are untouched.
func (t *Tracker[P]) InvalidateProviderPlan(
	providerID string,
	plan cacheplan.Plan,
	routeKey []byte,
	reason RemovalReason,
) {
	for _, anchor := range plan.Boundaries {
		for _, tier := range [...]string{"ssd", "memory"} {
			if key := CacheTierBoundaryKey(routeKey, plan, anchor, tier); key != "" {
				t.RemoveHolderLocked(key, providerID, reason)
			}
		}
	}
}

// SettleParkedChunk discards one chunk of the rows parked under (epoch,
// model) because no bind will take them again (the model's SSD capability is
// gone or moved to another cache epoch), settling each durable row against
// the holders still live instead of deleting it outright: with overlapping
// sessions of one machine, a row parked by a disconnected session may still
// be a live session's evidence. It reports whether rows remain; the registry
// re-checks between chunks that the bucket is still one no bind will take
// (dropParkedWhileStale), and a request that needs the tracker lock waits
// for at most one chunk.
func (t *Tracker[P]) SettleParkedChunk(epoch, model string) (more bool) {
	p := t.persister
	if p == nil {
		return false
	}
	rows, more := p.Take(epoch, model, bindChunkRows)
	for _, rec := range rows {
		t.PersistRowAfterLossLocked(rec.Key, rec.CacheEpoch, "", rec.UpdatedAt)
	}
	if len(rows) > 0 {
		p.AddBound(0, uint64(len(rows)))
	}
	return more
}
