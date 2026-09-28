package registry

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Cache routing state persistence.
//
// The tracker's holder index and demand index are the serving copy and stay
// in memory. This file keeps a durable copy in the store behind them so a
// coordinator restart does not start from an empty index:
//
//   - Every SSD-tier holder upsert and every non-disconnect removal is marked
//     dirty under the tracker lock; a demand observation marks its keys dirty
//     under the demand lock. A ticker drains the dirty sets and writes them in
//     bounded batches outside both locks. Nothing here is on a request's
//     critical path, and a store failure only delays the next flush.
//   - Disconnects keep the durable row: the provider still has the file, and
//     its cache epoch identifies it again when it reconnects under a new
//     provider ID. The provider mints one epoch UUID per (model, identity,
//     layout) SSD root and persists it (SSDHybridCheckpointStoreFactory.swift,
//     SSDCacheEpochStore.swift), so an epoch names one model on one machine;
//     parked rows are keyed by (epoch, model) and the coordinator never has
//     to trust a provider-wide identity.
//   - A runtime ConfigureCacheRouting installs an empty tracker without
//     routing removals through the persister (clearRetired), so live rows of
//     the retired tracker stay in the store until they expire; only main
//     calls it today, once at boot.
//   - At boot the demand index is reloaded directly. Holder rows are parked by
//     cache epoch and bound to a provider the moment that provider's
//     capabilities are applied with a matching epoch, model and contract, so a
//     restored holder always carries a live *Provider like a fresh receipt.
//   - Memory-tier holders live 30 s and are not persisted.

const (
	cacheRoutingFlushInterval = 5 * time.Second
	cacheRoutingPruneInterval = 5 * time.Minute
	// cacheRoutingDemandPersistGranularity is the smallest advance of a demand
	// key's seen time that is worth a row update. The demand TTL is minutes,
	// so a one-minute granularity loses nothing and cuts the write rate under
	// a burst by the number of repeats per key per minute.
	cacheRoutingDemandPersistGranularity = time.Minute
	// cacheRoutingDemandFlushRows caps the demand rows one flush writes; the
	// rest carry over so the persister never turns into a second planner
	// under a traffic burst.
	cacheRoutingDemandFlushRows = 5_000
	// cacheRoutingHolderFlushRows caps holder upserts and deletes per flush the
	// same way, so a backlog after a store outage drains in bounded chunks
	// instead of one statement set that can never finish inside the flush
	// deadline.
	cacheRoutingHolderFlushRows = 5_000
	// cacheRoutingDirtyCap bounds the carried-over dirty sets when the store
	// is unavailable; beyond it the oldest evidence is dropped and counted.
	cacheRoutingDirtyCap = 4 * cacheRoutingMaxEntries
)

// CacheRoutingPersistenceStatus is the aggregate, content-free view exposed on
// the cache status lifecycle block.
type CacheRoutingPersistenceStatus struct {
	Enabled         bool   `json:"enabled"`
	RestoredHolders int    `json:"restored_holders"`
	RestoredDemand  int    `json:"restored_demand"`
	PendingHolders  int    `json:"pending_holders"`
	BoundHolders    uint64 `json:"bound_holders"`
	DroppedPending  uint64 `json:"dropped_pending"`
	Flushes         uint64 `json:"flushes"`
	FlushErrors     uint64 `json:"flush_errors"`
	RowsWritten     uint64 `json:"rows_written"`
	RowsDeleted     uint64 `json:"rows_deleted"`
	DroppedDirty    uint64 `json:"dropped_dirty"`
	LastFlushMs     int64  `json:"last_flush_ms"`
	LastFlushAt     string `json:"last_flush_at,omitempty"`
}

type cacheRoutingPersister struct {
	store  store.CacheRoutingStateStore
	logger *slog.Logger

	mu              sync.Mutex
	holderUpserts   map[store.CacheHolderKey]store.CacheHolderRecord
	holderDeletes   map[store.CacheHolderKey]struct{}
	demandTouched   map[string]time.Time
	demandPersisted map[string]time.Time
	// pending holds restored and parked rows by (cache epoch, model) until
	// the provider that owns that epoch applies a capability for that model.
	pending      map[string][]store.CacheHolderRecord
	pendingCount int

	restoredHolders int
	restoredDemand  int
	boundHolders    uint64
	droppedPending  uint64
	flushes         uint64
	flushErrors     uint64
	rowsWritten     uint64
	rowsDeleted     uint64
	droppedDirty    uint64
	lastFlushMs     int64
	lastFlushAt     time.Time
}

func newCacheRoutingPersister(st store.CacheRoutingStateStore, logger *slog.Logger) *cacheRoutingPersister {
	if logger == nil {
		logger = slog.Default()
	}
	return &cacheRoutingPersister{
		store: st, logger: logger,
		holderUpserts:   make(map[store.CacheHolderKey]store.CacheHolderRecord),
		holderDeletes:   make(map[store.CacheHolderKey]struct{}),
		demandTouched:   make(map[string]time.Time),
		demandPersisted: make(map[string]time.Time),
		pending:         make(map[string][]store.CacheHolderRecord),
	}
}

// pendingKey groups parked rows by the provider root and the model, so binding
// one capability never consumes another model's rows under the same epoch.
func pendingKey(epoch, model string) string { return epoch + "\x00" + model }

func holderRecordFor(key string, h cacheHolder) store.CacheHolderRecord {
	return store.CacheHolderRecord{
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

// markHolderUpsert runs under tracker.mu; it only touches the persister's own
// maps, so the lock order tracker.mu → persister.mu is the only one used.
func (p *cacheRoutingPersister) markHolderUpsert(key string, h cacheHolder) {
	if p == nil || !h.persistable() {
		return
	}
	rec := holderRecordFor(key, h)
	p.mu.Lock()
	delete(p.holderDeletes, rec.HolderKey())
	if _, present := p.holderUpserts[rec.HolderKey()]; present || len(p.holderUpserts) < cacheRoutingDirtyCap {
		p.holderUpserts[rec.HolderKey()] = rec
	} else {
		p.droppedDirty++
	}
	p.mu.Unlock()
}

func (p *cacheRoutingPersister) markHolderDelete(key string, h cacheHolder) {
	if p == nil || !h.persistable() {
		return
	}
	k := store.CacheHolderKey{Key: key, CacheEpoch: h.CacheEpoch}
	p.mu.Lock()
	delete(p.holderUpserts, k)
	if _, present := p.holderDeletes[k]; present || len(p.holderDeletes) < cacheRoutingDirtyCap {
		p.holderDeletes[k] = struct{}{}
	} else {
		p.droppedDirty++
	}
	p.mu.Unlock()
}

// cancelDelete forgets a pending delete for a row that is live again.
func (p *cacheRoutingPersister) cancelDelete(key, epoch string) {
	if p == nil {
		return
	}
	p.mu.Lock()
	delete(p.holderDeletes, store.CacheHolderKey{Key: key, CacheEpoch: epoch})
	p.mu.Unlock()
}

// markDemand records keys the demand tracker just observed. It skips keys
// whose persisted seen time is within the granularity window.
func (p *cacheRoutingPersister) markDemand(keys []string, now time.Time) {
	if p == nil || len(keys) == 0 {
		return
	}
	p.mu.Lock()
	for _, key := range keys {
		if last, ok := p.demandPersisted[key]; ok && now.Sub(last) < cacheRoutingDemandPersistGranularity {
			continue
		}
		prev, present := p.demandTouched[key]
		if present && !now.After(prev) {
			continue
		}
		if !present && len(p.demandTouched) >= cacheRoutingDirtyCap {
			p.droppedDirty++
			continue
		}
		p.demandTouched[key] = now
	}
	p.mu.Unlock()
}

type cacheRoutingDirtyBatch struct {
	upserts []store.CacheHolderRecord
	deletes []store.CacheHolderKey
	demand  []store.CacheDemandRecord
	carried map[string]time.Time
}

func (p *cacheRoutingPersister) drain() cacheRoutingDirtyBatch {
	p.mu.Lock()
	defer p.mu.Unlock()
	batch := cacheRoutingDirtyBatch{
		upserts: make([]store.CacheHolderRecord, 0, min(len(p.holderUpserts), cacheRoutingHolderFlushRows)),
		deletes: make([]store.CacheHolderKey, 0, min(len(p.holderDeletes), cacheRoutingHolderFlushRows)),
	}
	for k, rec := range p.holderUpserts {
		if len(batch.upserts) >= cacheRoutingHolderFlushRows {
			break
		}
		batch.upserts = append(batch.upserts, rec)
		delete(p.holderUpserts, k)
	}
	for k := range p.holderDeletes {
		if len(batch.deletes) >= cacheRoutingHolderFlushRows {
			break
		}
		batch.deletes = append(batch.deletes, k)
		delete(p.holderDeletes, k)
	}
	batch.demand = make([]store.CacheDemandRecord, 0, min(len(p.demandTouched), cacheRoutingDemandFlushRows))
	for key, seen := range p.demandTouched {
		if len(batch.demand) >= cacheRoutingDemandFlushRows {
			break
		}
		batch.demand = append(batch.demand, store.CacheDemandRecord{Key: key, SeenAt: seen})
		delete(p.demandTouched, key)
	}
	return batch
}

// requeue merges a failed batch back so the next flush retries it, bounded by
// the dirty cap. Newer marks made meanwhile win.
func (p *cacheRoutingPersister) requeue(batch cacheRoutingDirtyBatch) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, rec := range batch.upserts {
		k := rec.HolderKey()
		if _, deleted := p.holderDeletes[k]; deleted {
			continue
		}
		if _, newer := p.holderUpserts[k]; newer {
			continue
		}
		if len(p.holderUpserts) >= cacheRoutingDirtyCap {
			p.droppedDirty++
			continue
		}
		p.holderUpserts[k] = rec
	}
	for _, k := range batch.deletes {
		if _, newer := p.holderUpserts[k]; newer {
			continue
		}
		if len(p.holderDeletes) >= cacheRoutingDirtyCap {
			p.droppedDirty++
			continue
		}
		p.holderDeletes[k] = struct{}{}
	}
	for _, rec := range batch.demand {
		if prev, ok := p.demandTouched[rec.Key]; ok && !rec.SeenAt.After(prev) {
			continue
		}
		if len(p.demandTouched) >= cacheRoutingDirtyCap {
			p.droppedDirty++
			continue
		}
		p.demandTouched[rec.Key] = rec.SeenAt
	}
}

// flush writes one drained batch in store-sized chunks. On a failure only the
// chunks not yet written are requeued, so a backlog after an outage drains
// forward instead of retrying the same set forever. It holds no tracker lock
// while talking to the store.
func (p *cacheRoutingPersister) flush(ctx context.Context) error {
	if p == nil {
		return nil
	}
	batch := p.drain()
	if len(batch.upserts) == 0 && len(batch.deletes) == 0 && len(batch.demand) == 0 {
		return nil
	}
	started := time.Now()
	var (
		err                    error
		wrote, deleted, demand int
	)
	for wrote < len(batch.upserts) && err == nil {
		end := min(wrote+store.CacheRoutingStateBatchRows, len(batch.upserts))
		if err = p.store.UpsertCacheHolders(ctx, batch.upserts[wrote:end]); err == nil {
			wrote = end
		}
	}
	for deleted < len(batch.deletes) && err == nil {
		end := min(deleted+store.CacheRoutingStateBatchRows, len(batch.deletes))
		if err = p.store.DeleteCacheHolders(ctx, batch.deletes[deleted:end]); err == nil {
			deleted = end
		}
	}
	for demand < len(batch.demand) && err == nil {
		end := min(demand+store.CacheRoutingStateBatchRows, len(batch.demand))
		if err = p.store.UpsertCacheDemand(ctx, batch.demand[demand:end]); err == nil {
			demand = end
		}
	}
	p.mu.Lock()
	p.flushes++
	p.lastFlushMs = time.Since(started).Milliseconds()
	p.lastFlushAt = time.Now()
	if err != nil {
		p.flushErrors++
	}
	p.rowsWritten += uint64(wrote + demand)
	p.rowsDeleted += uint64(deleted)
	for _, rec := range batch.demand[:demand] {
		p.demandPersisted[rec.Key] = rec.SeenAt
	}
	p.mu.Unlock()
	if err != nil {
		p.requeue(cacheRoutingDirtyBatch{
			upserts: batch.upserts[wrote:], deletes: batch.deletes[deleted:], demand: batch.demand[demand:],
		})
		p.logger.Warn("cache routing persistence flush failed; unwritten rows requeued", "error", err,
			"upserts_left", len(batch.upserts)-wrote, "deletes_left", len(batch.deletes)-deleted,
			"demand_left", len(batch.demand)-demand)
	}
	return err
}

// flushAll drains repeatedly until nothing is dirty, an error occurs or the
// context ends. Used by the shutdown flush, where the loop has stopped and a
// long drain may have marked more than one flush's worth.
func (p *cacheRoutingPersister) flushAll(ctx context.Context) error {
	if p == nil {
		return nil
	}
	for i := 0; i < 256; i++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := p.flush(ctx); err != nil {
			return err
		}
		p.mu.Lock()
		empty := len(p.holderUpserts) == 0 && len(p.holderDeletes) == 0 && len(p.demandTouched) == 0
		p.mu.Unlock()
		if empty {
			return nil
		}
	}
	return nil
}

// prune removes expired rows from the store and forgets the persisted-demand
// dedupe map, which is only a write-rate optimisation and may be reset freely.
func (p *cacheRoutingPersister) prune(ctx context.Context, now time.Time, demandTTL time.Duration) {
	if p == nil {
		return
	}
	if _, err := p.store.PruneCacheRoutingState(ctx, now, now.Add(-demandTTL)); err != nil {
		p.logger.Warn("cache routing persistence prune failed", "error", err)
	}
	p.prunePending(now)
	p.mu.Lock()
	p.demandPersisted = make(map[string]time.Time)
	p.mu.Unlock()
}

// restore loads the durable copy: demand entries go straight into the demand
// index; holder rows wait in pending until their provider applies its
// capabilities (see bindPendingLocked).
func (p *cacheRoutingPersister) restore(ctx context.Context, t *cacheRoutingTracker, now time.Time) error {
	if p == nil || t == nil {
		return nil
	}
	demandTTL := t.ttl
	demand, err := p.store.LoadCacheDemand(ctx, now.Add(-demandTTL))
	if err != nil {
		return err
	}
	holders, err := p.store.LoadCacheHolders(ctx, now)
	if err != nil {
		return err
	}
	restoredDemand := t.demand.restore(demand, now)
	p.mu.Lock()
	p.pending = make(map[string][]store.CacheHolderRecord)
	p.pendingCount = 0
	for _, rec := range holders {
		if p.pendingCount >= t.maxEntries {
			p.droppedPending++
			continue
		}
		pk := pendingKey(rec.CacheEpoch, rec.ModelID)
		p.pending[pk] = append(p.pending[pk], rec)
		p.pendingCount++
	}
	p.restoredHolders = p.pendingCount
	p.restoredDemand = restoredDemand
	for _, rec := range demand {
		p.demandPersisted[rec.Key] = rec.SeenAt
	}
	p.mu.Unlock()
	return nil
}

// parkHolder keeps a holder whose provider disconnected: the file is still on
// that machine, and its epoch binds the row again when it reconnects, whether
// that happens in this process or after a restart (the durable row is kept
// too). Bounded by the index cap; expired rows are dropped at bind and prune.
func (p *cacheRoutingPersister) parkHolder(key string, h cacheHolder) {
	if p == nil || !h.persistable() {
		return
	}
	rec := holderRecordFor(key, h)
	p.mu.Lock()
	if p.pendingCount < cacheRoutingMaxEntries {
		pk := pendingKey(rec.CacheEpoch, rec.ModelID)
		p.pending[pk] = append(p.pending[pk], rec)
		p.pendingCount++
	} else {
		p.droppedPending++
	}
	p.mu.Unlock()
}

// prunePending drops parked rows past their own expiry: their provider never
// came back in time.
func (p *cacheRoutingPersister) prunePending(now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for epoch, rows := range p.pending {
		kept := rows[:0]
		for _, rec := range rows {
			if rec.ExpiresAt.After(now) {
				kept = append(kept, rec)
			} else {
				p.droppedPending++
				p.pendingCount--
			}
		}
		if len(kept) == 0 {
			delete(p.pending, epoch)
		} else {
			p.pending[epoch] = kept
		}
	}
}

// hasPending reports whether any restored or parked rows await a provider.
func (p *cacheRoutingPersister) hasPending() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingCount > 0
}

// dropPending discards the rows parked under one (cache epoch, model) and
// schedules their durable rows for deletion: the capability they described no
// longer exists.
func (p *cacheRoutingPersister) dropPending(epoch, model string) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	pk := pendingKey(epoch, model)
	rows := p.pending[pk]
	if len(rows) == 0 {
		return
	}
	delete(p.pending, pk)
	p.pendingCount -= len(rows)
	p.droppedPending += uint64(len(rows))
	for _, rec := range rows {
		k := rec.HolderKey()
		delete(p.holderUpserts, k)
		if _, present := p.holderDeletes[k]; present || len(p.holderDeletes) < cacheRoutingDirtyCap {
			p.holderDeletes[k] = struct{}{}
		} else {
			p.droppedDirty++
		}
	}
}

// takePending pops the rows parked under one (cache epoch, model).
func (p *cacheRoutingPersister) takePending(epoch, model string) []store.CacheHolderRecord {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	pk := pendingKey(epoch, model)
	rows := p.pending[pk]
	if len(rows) == 0 {
		return nil
	}
	delete(p.pending, pk)
	p.pendingCount -= len(rows)
	return rows
}

func (p *cacheRoutingPersister) status() CacheRoutingPersistenceStatus {
	if p == nil {
		return CacheRoutingPersistenceStatus{}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	s := CacheRoutingPersistenceStatus{
		Enabled: true, RestoredHolders: p.restoredHolders, RestoredDemand: p.restoredDemand,
		PendingHolders: p.pendingCount, BoundHolders: p.boundHolders, DroppedPending: p.droppedPending,
		Flushes: p.flushes, FlushErrors: p.flushErrors, RowsWritten: p.rowsWritten, RowsDeleted: p.rowsDeleted,
		DroppedDirty: p.droppedDirty, LastFlushMs: p.lastFlushMs,
	}
	if !p.lastFlushAt.IsZero() {
		s.LastFlushAt = p.lastFlushAt.UTC().Format(time.RFC3339)
	}
	return s
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
		rows := p.takePending(capability.CacheEpoch, capability.ModelID)
		if len(rows) == 0 {
			continue
		}
		bound := t.bindRowsLocked(provider, capability, rows, now)
		p.mu.Lock()
		p.boundHolders += bound
		p.droppedPending += uint64(len(rows)) - bound
		p.mu.Unlock()
	}
}

func (t *cacheRoutingTracker) bindRowsLocked(provider *Provider, capability protocol.PrefixCacheV2Capability, rows []store.CacheHolderRecord, now time.Time) (bound uint64) {
	t.restoring = true
	defer func() { t.restoring = false }()
	for _, rec := range rows {
		if !rec.ExpiresAt.After(now) || rec.ModelID != capability.ModelID ||
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
			t.persister.cancelDelete(rec.Key, rec.CacheEpoch)
			bound++
		}
	}
	return bound
}
