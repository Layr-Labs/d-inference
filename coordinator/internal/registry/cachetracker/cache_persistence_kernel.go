package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

func HolderRecordFor[P comparable](key string, h Holder[P]) crs.HolderRecord {
	rec := crs.HolderRecord{
		Key: key, CacheEpoch: h.CacheEpoch, Tier: h.Tier, ModelID: h.ModelID,
		ModelAggregateHash: h.ModelAggregateHash, PromptContractID: h.PromptContractID,
		BlockHashVersion: h.BlockHashVersion, ReadyBoundaryMode: h.ReadyBoundaryMode,
		// The boundary is named by Key alone; the chain hash stays in memory.
		AnchorTokenCount: h.Anchor.TokenCount, RequiredRecomputeTokens: h.RequiredRecomputeTokens,
		StageMs: h.StageMs, UpdatedAt: h.UpdatedAt, ExpiresAt: h.ExpiresAt,
	}
	// A lookup's measured stage cost outranks the Ready fallback until its
	// own deadline (cache_stage_measurement.go); it travels with the row so a
	// restart inside that window does not flip routing back to the estimate.
	if m := h.Measurement; m != nil {
		rec.MeasuredStageMs, rec.MeasuredExpiresAt = m.Milliseconds(), m.ExpiresAt()
	}
	return rec
}

func (t *Tracker[P]) PersistHolderUpsert(key string, h Holder[P]) {
	if t.persister == nil || t.restoring || !h.Persistable() {
		return
	}
	t.persister.MarkHolderUpsert(HolderRecordFor(key, h))
}

func (t *Tracker[P]) PersistHolderRemoval(key string, h Holder[P], reason RemovalReason) {
	if t.persister == nil || !h.Persistable() {
		return
	}
	switch reason {
	case cacheHolderRemovalDisconnect:
		// The provider still has the file; park the row for its return.
		t.persister.Park(HolderRecordFor(key, h))
	case cacheHolderRemovalTTL:
		// Loads filter expired rows and the store prune removes them.
	default:
		t.PersistRowAfterLossLocked(key, h.CacheEpoch, h.ProviderID, h.UpdatedAt)
	}
}

// PersistRowAfterLossLocked settles the durable row (key, epoch) after one
// holder for it is gone. Two sessions of one machine share that identity and
// can overlap: the per-key holder cap evicts the old session's holder as the
// new session's receipt arrives (capacity_eviction), or a row parked for the
// old session is taken by the new one and fails to match. If another live
// session (any provider but except) has newer evidence under the same epoch,
// its upsert supersedes the lost row. An older survivor cannot replace the
// store's newer-wins row, so delete the durable copy until a fresh receipt
// proves it again; the survivor stays routable in memory. Called with t.mu held.
func (t *Tracker[P]) PersistRowAfterLossLocked(key, epoch, except string, lostAt time.Time) {
	// With more than two overlapping sessions the row must reflect the
	// freshest surviving evidence, not whichever session the map yields.
	var (
		newest Holder[P]
		found  bool
		now    = t.now()
	)
	for providerID, other := range t.holders.Entries(key) {
		if providerID == except || other.CacheEpoch != epoch || !other.Persistable() {
			continue
		}
		if !other.ExpiresAt.After(now) || !other.UpdatedAt.After(lostAt) {
			continue
		}
		if !found || other.UpdatedAt.After(newest.UpdatedAt) {
			newest, found = other, true
		}
	}
	if found {
		t.persister.MarkHolderUpsert(HolderRecordFor(key, newest))
		return
	}
	t.persister.MarkHolderDelete(crs.HolderKey{Key: key, CacheEpoch: epoch}, now)
}

// BindPendingLocked binds up to one chunk of parked rows across the
// provider's capabilities and reports whether any of them still has rows
// parked.
func (t *Tracker[P]) BindPendingLocked(provider Binding[P], capabilities map[string]protocol.PrefixCacheV2Capability, now time.Time) (remaining bool) {
	p := t.persister
	if p == nil || provider.Provider == t.zero || len(capabilities) == 0 {
		return false
	}
	budget := bindChunkRows
	for _, capability := range capabilities {
		if capability.CacheEpoch == "" || capability.ModelID == "" {
			continue
		}
		if budget <= 0 {
			// This hold is spent; the caller's next chunk resumes here.
			remaining = true
			break
		}
		rows, more := p.Take(capability.CacheEpoch, capability.ModelID, budget)
		if len(rows) == 0 {
			continue
		}
		budget -= len(rows)
		bound := t.BindRowsLocked(provider, capability, rows, now)
		p.AddBound(bound, uint64(len(rows))-bound)
		if more {
			remaining = true
		}
	}
	return remaining
}

func (t *Tracker[P]) BindRowsLocked(provider Binding[P], capability protocol.PrefixCacheV2Capability, rows []crs.HolderRecord, now time.Time) (bound uint64) {
	t.restoring = true
	defer func() { t.restoring = false }()
	for _, rec := range rows {
		rec, ok := cachepersist.ClampToTTL(rec, now, t.ttl)
		if !ok {
			continue
		}
		if t.persister.Tombstoned(rec.HolderKey(), rec.UpdatedAt) {
			// This run already invalidated the holder (a miss, a proof
			// mismatch, an eviction) after this row's evidence was
			// produced: a retried restore loaded it while the delete was
			// queued, or an older session parked it before the decision.
			continue
		}
		if rec.ModelID != capability.ModelID ||
			rec.ModelAggregateHash != capability.ModelAggregateHash ||
			rec.PromptContractID != capability.PromptContractID ||
			rec.ReadyBoundaryMode != capability.ReadyBoundaryMode ||
			(rec.BlockHashVersion != "" && capability.BlockHashVersion != "" && rec.BlockHashVersion != capability.BlockHashVersion) {
			// The provider's capability for this epoch and model no longer
			// describes the checkpoint (a coordinator upgrade bumped the
			// block-hash version, or the artifact or contract moved); the
			// durable row would only be reloaded and rejected again on every
			// boot, unless a live holder still owns it.
			t.PersistRowAfterLossLocked(rec.Key, rec.CacheEpoch, "", rec.UpdatedAt)
			continue
		}
		if live, ok := t.holders.Bucket(rec.Key).Load(provider.ProviderID); ok && !rec.UpdatedAt.After(live.UpdatedAt) {
			// The provider already proved this boundary again on this
			// connection; the parked row is older evidence for the same thing.
			bound++
			continue
		}
		holder := Holder[P]{
			ProviderID: provider.ProviderID, Provider: provider.Provider, ModelID: rec.ModelID,
			ModelAggregateHash: rec.ModelAggregateHash, PromptContractID: rec.PromptContractID,
			BlockHashVersion: rec.BlockHashVersion, ReadyBoundaryMode: rec.ReadyBoundaryMode, CacheEpoch: rec.CacheEpoch, Tier: rec.Tier,
			// No chain hash at rest: the key bound the boundary, and a
			// restored holder matches its plan anchor by token count
			// (AnchorMatches) until a fresh receipt replaces it.
			Anchor:                  protocol.PrefixCacheAnchor{TokenCount: rec.AnchorTokenCount},
			RequiredRecomputeTokens: rec.RequiredRecomputeTokens, StageMs: rec.StageMs,
			UpdatedAt: rec.UpdatedAt, ExpiresAt: rec.ExpiresAt,
		}
		if rec.MeasuredStageMs > 0 && rec.MeasuredExpiresAt.After(now) {
			// The measurement binds to the capability the row bound to: the
			// identity fields (epoch, model, artifact, contract, block-hash
			// version, ready-boundary mode) all matched, the same contract an
			// in-session capability change invalidates on. It never outlives
			// the holder's (clamped) expiry.
			expires := rec.MeasuredExpiresAt
			if rec.ExpiresAt.Before(expires) {
				expires = rec.ExpiresAt
			}
			holder.Measurement = NewMeasurement(rec.MeasuredStageMs, expires, capability)

		}
		t.UpsertHolderLocked(rec.Key, holder)
		if _, present := t.holders.Bucket(rec.Key).Load(provider.ProviderID); present {
			bound++
		}
	}
	return bound
}
