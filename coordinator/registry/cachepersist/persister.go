// Package cachepersist keeps a durable copy of the registry's exact
// prefix-cache holder index and observed-demand index behind the in-memory
// serving copy, so a coordinator restart does not start from an empty index.
//
//   - The registry marks every SSD-tier holder upsert and every non-disconnect
//     removal dirty under its tracker lock; a demand observation marks its keys
//     dirty after the demand lock is released. A ticker drains the dirty sets
//     and writes them in bounded batches outside every registry lock. Nothing
//     here is on a request's critical path; a store failure only delays the
//     next flush, which retries the unwritten remainder.
//   - A disconnect parks the holder (pending.go) instead of deleting its row:
//     the provider still has the file, and its cache epoch identifies it
//     again when it reconnects under a new provider ID, in this process or
//     after a restart. The provider mints one epoch UUID per (model, identity,
//     layout) SSD root and persists it, so an epoch names one model on one
//     machine and pending rows are keyed by (epoch, model).
//   - At boot (restore.go) the demand index is handed back to the registry to
//     seed directly; holder rows are parked until the registry binds them to
//     a provider whose capabilities match.
//   - Memory-tier holders live 30 s and are never persisted; the registry
//     decides what is persistable before marking.
package cachepersist

import (
	"context"
	"log/slog"
	"sync"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

const (
	// FlushInterval is how often dirty entries are written.
	FlushInterval = 5 * time.Second
	// PruneInterval is how often expired rows are removed from the store and
	// expired parked rows are dropped.
	PruneInterval = 5 * time.Minute
	// DemandPersistGranularity is the smallest advance of a demand key's seen
	// time that is worth a row update. The demand TTL is minutes, so a
	// one-minute granularity loses nothing and cuts the write rate under a
	// burst by the number of repeats per key per minute.
	DemandPersistGranularity = time.Minute
	// DemandFlushRows and HolderFlushRows cap what one flush writes; the rest
	// carries over, so a backlog after a store outage drains forward in
	// bounded chunks and the persister never becomes a second planner.
	DemandFlushRows = 5_000
	HolderFlushRows = 5_000
)

// Persister owns the dirty sets, the parked rows and the write-behind loop's
// work. It is safe for concurrent use; its mutex is a leaf lock that never
// takes a registry lock.
type Persister struct {
	store  crs.Store
	logger *slog.Logger
	// maxPending bounds parked rows; dirtyCap bounds each dirty set when the
	// store is unavailable (beyond it the incoming mark is dropped and
	// counted).
	maxPending int
	dirtyCap   int
	// demandGranularity is DemandPersistGranularity bounded by the demand
	// TTL, so a short TTL never leaves the durable timestamp older than the
	// TTL while the key is still being refreshed in memory.
	demandGranularity time.Duration
	// fingerprint names the derived cache-key generation; rows stored under
	// another generation are reset at restore rather than restored.
	fingerprint string

	// flushMu serializes flushes so a shutdown flush cannot drain a later
	// delete before a periodic flush commits an older upsert, or observe empty
	// dirty sets while that flush is about to requeue a failed batch.
	flushMu sync.Mutex

	mu              sync.Mutex
	holderUpserts   map[crs.HolderKey]crs.HolderRecord
	holderDeletes   map[crs.HolderKey]struct{}
	demandTouched   map[string]time.Time
	demandPersisted map[string]time.Time
	pending         map[string][]crs.HolderRecord
	pendingCount    int
	counters        counters
}

// Options shape a persister for the registry's current configuration.
type Options struct {
	// MaxPending is the registry's holder index cap; the dirty sets allow
	// four times that before dropping marks.
	MaxPending int
	// DemandTTL is the routing TTL the demand index uses; it bounds the
	// demand persistence granularity.
	DemandTTL time.Duration
	// Fingerprint names the derived cache-key generation (non-secret).
	Fingerprint string
}

// New builds a persister over st.
func New(st crs.Store, logger *slog.Logger, opts Options) *Persister {
	if logger == nil {
		logger = slog.Default()
	}
	maxPending := opts.MaxPending
	if maxPending <= 0 {
		maxPending = 250_000
	}
	granularity := DemandPersistGranularity
	if opts.DemandTTL > 0 && opts.DemandTTL/4 < granularity {
		granularity = opts.DemandTTL / 4
	}
	return &Persister{
		store: st, logger: logger, maxPending: maxPending, dirtyCap: 4 * maxPending,
		demandGranularity: granularity, fingerprint: opts.Fingerprint,
		holderUpserts:   make(map[crs.HolderKey]crs.HolderRecord),
		holderDeletes:   make(map[crs.HolderKey]struct{}),
		demandTouched:   make(map[string]time.Time),
		demandPersisted: make(map[string]time.Time),
		pending:         make(map[string][]crs.HolderRecord),
	}
}

// MarkHolderUpsert schedules a row write. Nil-safe. The caller has already
// decided the holder is persistable.
func (p *Persister) MarkHolderUpsert(rec crs.HolderRecord) {
	if p == nil {
		return
	}
	k := rec.HolderKey()
	p.mu.Lock()
	delete(p.holderDeletes, k)
	if _, present := p.holderUpserts[k]; present || len(p.holderUpserts) < p.dirtyCap {
		p.holderUpserts[k] = rec
	} else {
		p.counters.droppedDirty++
	}
	p.mu.Unlock()
}

// MarkHolderDelete schedules a row delete. Nil-safe.
func (p *Persister) MarkHolderDelete(k crs.HolderKey) {
	if p == nil {
		return
	}
	p.mu.Lock()
	delete(p.holderUpserts, k)
	if _, present := p.holderDeletes[k]; present || len(p.holderDeletes) < p.dirtyCap {
		p.holderDeletes[k] = struct{}{}
	} else {
		p.counters.droppedDirty++
	}
	p.mu.Unlock()
}

// CancelDelete forgets a pending delete for a row that is live again.
func (p *Persister) CancelDelete(k crs.HolderKey) {
	if p == nil {
		return
	}
	p.mu.Lock()
	delete(p.holderDeletes, k)
	p.mu.Unlock()
}

// MarkDemand records keys the demand index just observed, skipping keys whose
// persisted seen time is within the demand granularity (DemandPersistGranularity
// bounded by the TTL, see New). Nil-safe.
func (p *Persister) MarkDemand(keys []string, now time.Time) {
	if p == nil || len(keys) == 0 {
		return
	}
	p.mu.Lock()
	for _, key := range keys {
		if last, ok := p.demandPersisted[key]; ok && now.Sub(last) < p.demandGranularity {
			continue
		}
		prev, present := p.demandTouched[key]
		if present && !now.After(prev) {
			continue
		}
		if !present && len(p.demandTouched) >= p.dirtyCap {
			p.counters.droppedDirty++
			continue
		}
		p.demandTouched[key] = now
	}
	p.mu.Unlock()
}

type batch struct {
	upserts []crs.HolderRecord
	deletes []crs.HolderKey
	demand  []crs.DemandRecord
}

func (p *Persister) drain() batch {
	p.mu.Lock()
	defer p.mu.Unlock()
	b := batch{
		upserts: make([]crs.HolderRecord, 0, min(len(p.holderUpserts), HolderFlushRows)),
		deletes: make([]crs.HolderKey, 0, min(len(p.holderDeletes), HolderFlushRows)),
		demand:  make([]crs.DemandRecord, 0, min(len(p.demandTouched), DemandFlushRows)),
	}
	for k, rec := range p.holderUpserts {
		if len(b.upserts) >= HolderFlushRows {
			break
		}
		b.upserts = append(b.upserts, rec)
		delete(p.holderUpserts, k)
	}
	for k := range p.holderDeletes {
		if len(b.deletes) >= HolderFlushRows {
			break
		}
		b.deletes = append(b.deletes, k)
		delete(p.holderDeletes, k)
	}
	for key, seen := range p.demandTouched {
		if len(b.demand) >= DemandFlushRows {
			break
		}
		b.demand = append(b.demand, crs.DemandRecord{Key: key, SeenAt: seen})
		delete(p.demandTouched, key)
	}
	return b
}

// requeue merges an unwritten remainder back so the next flush retries it,
// bounded by the dirty cap. Marks made meanwhile win.
func (p *Persister) requeue(b batch) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, rec := range b.upserts {
		k := rec.HolderKey()
		if _, deleted := p.holderDeletes[k]; deleted {
			continue
		}
		if _, newer := p.holderUpserts[k]; newer {
			continue
		}
		if len(p.holderUpserts) >= p.dirtyCap {
			p.counters.droppedDirty++
			continue
		}
		p.holderUpserts[k] = rec
	}
	for _, k := range b.deletes {
		if _, newer := p.holderUpserts[k]; newer {
			continue
		}
		if len(p.holderDeletes) >= p.dirtyCap {
			p.counters.droppedDirty++
			continue
		}
		p.holderDeletes[k] = struct{}{}
	}
	for _, rec := range b.demand {
		if prev, ok := p.demandTouched[rec.Key]; ok && !rec.SeenAt.After(prev) {
			continue
		}
		if len(p.demandTouched) >= p.dirtyCap {
			p.counters.droppedDirty++
			continue
		}
		p.demandTouched[rec.Key] = rec.SeenAt
	}
}

// Flush writes one drained batch in store-sized chunks. Flushes are
// serialized; on a failure only the chunks not yet written are requeued.
func (p *Persister) Flush(ctx context.Context) error {
	if p == nil {
		return nil
	}
	p.flushMu.Lock()
	defer p.flushMu.Unlock()
	b := p.drain()
	if len(b.upserts) == 0 && len(b.deletes) == 0 && len(b.demand) == 0 {
		return nil
	}
	started := time.Now()
	var (
		err                    error
		wrote, deleted, demand int
	)
	for wrote < len(b.upserts) && err == nil {
		end := min(wrote+crs.BatchRows, len(b.upserts))
		if err = p.store.UpsertCacheHolders(ctx, b.upserts[wrote:end]); err == nil {
			wrote = end
		}
	}
	for deleted < len(b.deletes) && err == nil {
		end := min(deleted+crs.BatchRows, len(b.deletes))
		if err = p.store.DeleteCacheHolders(ctx, b.deletes[deleted:end]); err == nil {
			deleted = end
		}
	}
	for demand < len(b.demand) && err == nil {
		end := min(demand+crs.BatchRows, len(b.demand))
		if err = p.store.UpsertCacheDemand(ctx, b.demand[demand:end]); err == nil {
			demand = end
		}
	}
	p.mu.Lock()
	p.counters.flushes++
	p.counters.lastFlushMs = time.Since(started).Milliseconds()
	p.counters.lastFlushAt = time.Now()
	if err != nil {
		p.counters.flushErrors++
	}
	p.counters.rowsWritten += uint64(wrote + demand)
	p.counters.rowsDeleted += uint64(deleted)
	for _, rec := range b.demand[:demand] {
		p.demandPersisted[rec.Key] = rec.SeenAt
	}
	p.mu.Unlock()
	if err != nil {
		p.requeue(batch{upserts: b.upserts[wrote:], deletes: b.deletes[deleted:], demand: b.demand[demand:]})
		p.logger.Warn("cache routing persistence flush failed; unwritten rows requeued", "error", err,
			"upserts_left", len(b.upserts)-wrote, "deletes_left", len(b.deletes)-deleted,
			"demand_left", len(b.demand)-demand)
	}
	return err
}

// FlushAll flushes repeatedly until nothing is dirty, an error occurs or the
// context ends. Used by the shutdown flush after the loop has stopped.
func (p *Persister) FlushAll(ctx context.Context) error {
	if p == nil {
		return nil
	}
	for i := 0; i < 256; i++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := p.Flush(ctx); err != nil {
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

// Prune removes expired rows from the store, drops expired parked rows and
// forgets the persisted-demand dedupe map, which is only a write-rate
// optimisation and may be reset freely.
func (p *Persister) Prune(ctx context.Context, now time.Time, demandTTL time.Duration) {
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

// dirtyEmpty is for tests.
func (p *Persister) dirtyEmpty() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.holderUpserts) == 0 && len(p.holderDeletes) == 0 && len(p.demandTouched) == 0
}
