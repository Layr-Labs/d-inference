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
	return crs.HolderRecord{
		Key: key, CacheEpoch: h.CacheEpoch, Tier: h.Tier, ModelID: h.ModelID,
		ModelAggregateHash: h.ModelAggregateHash, PromptContractID: h.PromptContractID,
		BlockHashVersion: h.BlockHashVersion, AnchorChainHash: h.Anchor.ChainHash,
		AnchorTokenCount: h.Anchor.TokenCount, RequiredRecomputeTokens: h.RequiredRecomputeTokens,
		StageMs: h.StageMs, UpdatedAt: h.UpdatedAt, ExpiresAt: h.ExpiresAt,
	}
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
		t.persister.MarkHolderDelete(crs.HolderKey{Key: key, CacheEpoch: h.CacheEpoch})
	}
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
		if !ok || rec.ModelID != capability.ModelID ||
			rec.ModelAggregateHash != capability.ModelAggregateHash ||
			rec.PromptContractID != capability.PromptContractID ||
			(rec.BlockHashVersion != "" && capability.BlockHashVersion != "" && rec.BlockHashVersion != capability.BlockHashVersion) {
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
		t.upsertHolderLocked(rec.Key, holder)
		if _, present := t.holders[rec.Key][provider.ID]; present {
			t.persister.CancelDelete(rec.HolderKey())
			bound++
		}
	}
	return bound
}
