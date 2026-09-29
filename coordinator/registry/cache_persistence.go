package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Registry-side glue for cache routing state persistence. The persister
// (registry/cachepersist) owns the dirty sets, the parked rows and the
// write-behind work; this file decides what is persistable, converts holders
// to durable records, and binds parked rows back into the tracker through
// the ordinary upsert path. Wiring (start, loop, final flush, status) is in
// cache_persistence_registry.go.
//
// A runtime ConfigureCacheRouting installs an empty tracker without routing
// removals through the persister (clearRetired), so live rows of the retired
// tracker stay in the store until they expire; only main calls it today, once
// at boot.

func holderRecordFor(key string, h cacheHolder) crs.HolderRecord {
	rec := crs.HolderRecord{
		Key: key, CacheEpoch: h.CacheEpoch, Tier: h.Tier, ModelID: h.ModelID,
		ModelAggregateHash: h.ModelAggregateHash, PromptContractID: h.PromptContractID,
		BlockHashVersion: h.BlockHashVersion, AnchorChainHash: h.Anchor.ChainHash,
		AnchorTokenCount: h.Anchor.TokenCount, RequiredRecomputeTokens: h.RequiredRecomputeTokens,
		StageMs: h.StageMs, UpdatedAt: h.UpdatedAt, ExpiresAt: h.ExpiresAt,
	}
	// A lookup's measured stage cost outranks the Ready fallback until its
	// own deadline (cache_stage_measurement.go); it travels with the row so a
	// restart inside that window does not flip routing back to the estimate.
	if m := h.stageMeasurement; m != nil {
		rec.MeasuredStageMs, rec.MeasuredExpiresAt = m.milliseconds, m.expiresAt
	}
	return rec
}

// persistable reports whether a holder belongs in the durable copy: SSD tier
// with a cache epoch. Memory-tier holders expire in seconds.
func (h cacheHolder) persistable() bool {
	return h.Tier != "memory" && h.CacheEpoch != "" && h.ModelID != ""
}

// Hooks called under tracker.mu. The persister's lock is a leaf lock, so
// tracker.mu → persister.mu is the only order used.

func (t *cacheRoutingTracker) persistHolderUpsert(key string, h cacheHolder) {
	if t.persister == nil || t.restoring || !h.persistable() {
		return
	}
	t.persister.MarkHolderUpsert(holderRecordFor(key, h))
}

func (t *cacheRoutingTracker) persistHolderRemoval(key string, h cacheHolder, reason cacheHolderRemovalReason) {
	if t.persister == nil || !h.persistable() {
		return
	}
	switch reason {
	case cacheHolderRemovalDisconnect:
		// The provider still has the file; park the row for its return.
		t.persister.Park(holderRecordFor(key, h))
	case cacheHolderRemovalTTL:
		// Loads filter expired rows and the store prune removes them.
	default:
		t.persistRowAfterLossLocked(key, h.CacheEpoch, h.ProviderID)
	}
}

// dropParkedForCapability discards the rows parked under (epoch, model)
// because that capability no longer exists, settling each durable row
// against the holders still live instead of deleting it outright: with
// overlapping sessions of one machine, a row parked by a disconnected
// session may still be a live session's evidence.
func (t *cacheRoutingTracker) dropParkedForCapability(epoch, model string) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	p := t.persister
	if p == nil {
		return
	}
	rows := p.Take(epoch, model)
	if len(rows) == 0 {
		return
	}
	for _, rec := range rows {
		t.persistRowAfterLossLocked(rec.Key, rec.CacheEpoch, "")
	}
	p.AddBound(0, uint64(len(rows)))
}

// persistRowAfterLossLocked settles the durable row (key, epoch) after one
// holder for it is gone. Two sessions of one machine share that identity and
// can overlap: the per-key holder cap evicts the old session's holder as the
// new session's receipt arrives (capacity_eviction), or a row parked for the
// old session is taken by the new one and fails to match. If another live
// session (any provider but except) still holds the boundary under the same
// epoch, the row is its evidence now and is refreshed; otherwise it is
// deleted. Called with t.mu held.
func (t *cacheRoutingTracker) persistRowAfterLossLocked(key, epoch, except string) {
	// With more than two overlapping sessions the row must reflect the
	// freshest surviving evidence, not whichever session the map yields.
	var (
		newest cacheHolder
		found  bool
	)
	for providerID, other := range t.holders[key] {
		if providerID == except || other.CacheEpoch != epoch || !other.persistable() {
			continue
		}
		if !found || other.UpdatedAt.After(newest.UpdatedAt) {
			newest, found = other, true
		}
	}
	if found {
		t.persister.MarkHolderUpsert(holderRecordFor(key, newest))
		return
	}
	t.persister.MarkHolderDelete(crs.HolderKey{Key: key, CacheEpoch: epoch})
}

// bindPendingLocked runs under tracker.mu (and the provider's lock, in the
// same order the receipt path uses) whenever a provider's SSD capabilities are
// applied, whether or not they changed: registration already carries them, so
// a reconnecting provider's first apply is an unchanged one. Every parked row
// whose epoch, model, artifact and contract match the capability becomes a
// live holder through the ordinary upsert path, so the per-key cap, the
// expiry heap and the per-provider index all apply. A parked row never
// overwrites a newer live holder the same provider already produced, and any
// pending delete for the row is cancelled because the row is live again. The
// restoring flag keeps the upsert from re-marking a row the store already has.
func (t *cacheRoutingTracker) bindPendingLocked(provider *Provider, capabilities map[string]protocol.PrefixCacheV2Capability, now time.Time) {
	p := t.persister
	if p == nil || provider == nil || len(capabilities) == 0 {
		return
	}
	for _, capability := range capabilities {
		if capability.CacheEpoch == "" || capability.ModelID == "" {
			continue
		}
		rows := p.Take(capability.CacheEpoch, capability.ModelID)
		if len(rows) == 0 {
			continue
		}
		bound := t.bindRowsLocked(provider, capability, rows, now)
		p.AddBound(bound, uint64(len(rows))-bound)
	}
}

func (t *cacheRoutingTracker) bindRowsLocked(provider *Provider, capability protocol.PrefixCacheV2Capability, rows []crs.HolderRecord, now time.Time) (bound uint64) {
	t.restoring = true
	defer func() { t.restoring = false }()
	for _, rec := range rows {
		rec, ok := cachepersist.ClampToTTL(rec, now, t.ttl)
		if !ok {
			continue
		}
		if rec.ModelID != capability.ModelID ||
			rec.ModelAggregateHash != capability.ModelAggregateHash ||
			rec.PromptContractID != capability.PromptContractID ||
			(rec.BlockHashVersion != "" && capability.BlockHashVersion != "" && rec.BlockHashVersion != capability.BlockHashVersion) {
			// The provider's capability for this epoch and model no longer
			// describes the checkpoint (a coordinator upgrade bumped the
			// block-hash version, or the artifact or contract moved); the
			// durable row would only be reloaded and rejected again on every
			// boot, unless a live holder still owns it.
			t.persistRowAfterLossLocked(rec.Key, rec.CacheEpoch, "")
			continue
		}
		if live, ok := t.holders[rec.Key][provider.ID]; ok && !rec.UpdatedAt.After(live.UpdatedAt) {
			// The provider already proved this boundary again on this
			// connection; the parked row is older evidence for the same thing.
			bound++
			continue
		}
		holder := cacheHolder{
			ProviderID: provider.ID, Provider: provider, ModelID: rec.ModelID,
			ModelAggregateHash: rec.ModelAggregateHash, PromptContractID: rec.PromptContractID,
			BlockHashVersion: rec.BlockHashVersion, CacheEpoch: rec.CacheEpoch, Tier: rec.Tier,
			Anchor:                  protocol.PrefixCacheAnchor{ChainHash: rec.AnchorChainHash, TokenCount: rec.AnchorTokenCount},
			RequiredRecomputeTokens: rec.RequiredRecomputeTokens, StageMs: rec.StageMs,
			UpdatedAt: rec.UpdatedAt, ExpiresAt: rec.ExpiresAt,
		}
		if rec.MeasuredStageMs > 0 && rec.MeasuredExpiresAt.After(now) {
			// The measurement binds to the capability the row bound to; the
			// same identity fields matched, and any other change would have
			// invalidated the holder in memory as well. It never outlives the
			// holder's (clamped) expiry.
			expires := rec.MeasuredExpiresAt
			if rec.ExpiresAt.Before(expires) {
				expires = rec.ExpiresAt
			}
			holder.stageMeasurement = &cacheStageMeasurement{
				milliseconds: rec.MeasuredStageMs, expiresAt: expires, capability: capability,
			}
		}
		t.upsertHolderLocked(rec.Key, holder)
		if _, present := t.holders[rec.Key][provider.ID]; present {
			t.persister.CancelDelete(rec.HolderKey())
			bound++
		}
	}
	return bound
}
