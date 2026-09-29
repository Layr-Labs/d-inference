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
	"container/heap"
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
	// store is unavailable: beyond it an incoming upsert or demand mark is
	// dropped and counted, while a delete resets the durable copy instead
	// (MarkHolderDelete) and a requeued delete is kept (requeue).
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

	mu            sync.Mutex
	holderUpserts map[crs.HolderKey]crs.HolderRecord
	// holderDeletes holds the time each pending delete was decided;
	// recentDeletes keeps that time from the moment the delete leaves the
	// dirty set (in flight or written) for one TTL, so a row parked before
	// the decision (an older session of the same machine) still cannot bind
	// once the tombstone is no longer pending (Tombstoned).
	holderDeletes map[crs.HolderKey]time.Time
	recentDeletes map[crs.HolderKey]time.Time
	// recentOrder orders the recorded decisions by decision time, indexed by
	// identity (one entry per decision), so the retention bound evicts the
	// oldest decision first whatever order the flushes recorded them in, a
	// key decided again moves to its new time, and the TTL prune forgets
	// from the oldest end in bounded chunks (Prune) instead of scanning the
	// whole set under p.mu.
	recentOrder keyedTimeHeap
	// retentionLimit bounds recentDeletes: the holder budget, but never
	// below one flush batch, or the cap could evict a tombstone whose
	// delete is still in flight.
	retentionLimit  int
	demandTouched   map[string]time.Time
	demandPersisted map[string]time.Time
	// pending holds parked rows per (cache epoch, model) bucket, indexed by
	// durable identity so a park, a merge and a tombstone check are O(1);
	// a disconnect parks one row per holder under the tracker lock.
	pending map[string]map[crs.HolderKey]crs.HolderRecord
	// parkedBucket maps each parked row's durable identity to its bucket, so
	// a delete decision can discard the parked copy it outranks at once
	// (MarkHolderDelete) without knowing the model.
	parkedBucket map[crs.HolderKey]string
	// parkedExpiry orders parked rows by expiry so a prune pops only the
	// expired ones, in bounded chunks per lock hold, instead of scanning
	// every parked row under p.mu (a receipt holding the tracker lock waits
	// on this mutex, and requests wait on the tracker lock). It indexes its
	// entries by identity and holds exactly one per parked row: a take or a
	// drop removes the row's entry and a merge moves it, so no maintenance
	// pass ever runs under the tracker lock.
	parkedExpiry keyedTimeHeap
	pendingCount int
	counters     counters
	// ready is set once Restore has established the key generation (and
	// loaded the durable copy). Until then flushes and prunes are no-ops
	// and marks stay dirty: rows written before the generation is recorded
	// would be reset as foreign by the next boot.
	ready bool
	// resetPending is set when the delete backlog outgrew its budget during
	// a store outage (MarkHolderDelete): rather than dropping a delete,
	// whose durable row a restart would restore as evidence a miss or proof
	// mismatch already invalidated, the whole durable copy is discarded at
	// the next flush, or by the restore if none has succeeded yet, and
	// rewritten from the evidence that flows afterwards.
	resetPending bool
	// overflowSeq counts backlog overflows. A batch drained under an earlier
	// count was in flight when decisions were released, so its upserts are
	// not requeued: one may be evidence a released decision condemned.
	overflowSeq uint64
}

// Options shape a persister for the registry's current configuration.
type Options struct {
	// MaxPending is the registry's holder index cap; the dirty sets allow
	// four times that before dropping upsert and demand marks (a delete is
	// never dropped: past the cap it resets the durable copy instead).
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
		retentionLimit:    max(maxPending, HolderFlushRows),
		demandGranularity: granularity, fingerprint: opts.Fingerprint,
		holderUpserts:   make(map[crs.HolderKey]crs.HolderRecord),
		holderDeletes:   make(map[crs.HolderKey]time.Time),
		recentDeletes:   make(map[crs.HolderKey]time.Time),
		recentOrder:     keyedTimeHeap{pos: make(map[crs.HolderKey]int)},
		demandTouched:   make(map[string]time.Time),
		demandPersisted: make(map[string]time.Time),
		pending:         make(map[string]map[crs.HolderKey]crs.HolderRecord),
		parkedBucket:    make(map[crs.HolderKey]string),
		parkedExpiry:    keyedTimeHeap{pos: make(map[crs.HolderKey]int)},
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
	defer p.mu.Unlock()
	// Receipt times are sampled before the tracker lock: a receipt older
	// than a delete this run decided (pending, or written within the TTL)
	// is stale evidence and must neither cancel the tombstone nor reach the
	// store. A newer receipt re-proves the row and cancels the tombstone.
	// Ties go to the delete: a receipt that sampled the same clock value as
	// the invalidation, before waiting on the tracker lock, was sampled
	// before the decision.
	if at, pending := p.holderDeletes[k]; pending && !rec.UpdatedAt.After(at) {
		p.counters.staleUpserts++
		return
	}
	if at, ok := p.recentDeletes[k]; ok && !rec.UpdatedAt.After(at) {
		p.counters.staleUpserts++
		return
	}
	delete(p.holderDeletes, k)
	if existing, present := p.holderUpserts[k]; present {
		// Receipt times are sampled before the tracker lock, so a delayed
		// older receipt for a row shared by overlapping sessions can arrive
		// after a newer one: keep the newer evidence, as the store would.
		p.holderUpserts[k] = crs.Later(existing, rec)
	} else if len(p.holderUpserts) < p.dirtyCap {
		p.holderUpserts[k] = rec
	} else {
		p.counters.droppedDirty++
	}
}

// MarkHolderDelete schedules a row delete. Nil-safe.
func (p *Persister) MarkHolderDelete(k crs.HolderKey, decidedAt time.Time) {
	if p == nil {
		return
	}
	p.mu.Lock()
	delete(p.holderUpserts, k)
	if _, present := p.holderDeletes[k]; !present && len(p.holderDeletes) >= p.dirtyCap {
		// The delete backlog is full: a store outage outlasted the budget.
		// A delete is never dropped (its durable row would be restored
		// after a restart as evidence a miss or proof mismatch already
		// invalidated); instead the durable copy is discarded wholesale at
		// the next flush, or by the restore if none has succeeded yet
		// (resetIfPending), which subsumes every delete queued so far. The
		// backlog is released with an O(1) swap and this decision starts
		// the next one. The released decisions leave no tombstone (recording
		// them would be a scan under the tracker lock): their parked copies
		// were dropped when they were decided, and the residual is the
		// retention bound's.
		p.resetPending = true
		p.overflowSeq++
		p.counters.overflowResets++
		p.holderDeletes = make(map[crs.HolderKey]time.Time)
	}
	// decidedAt comes from the tracker's clock, the same clock receipt
	// times are sampled from, so Tombstoned compares like with like.
	p.holderDeletes[k] = decidedAt
	// A parked copy this decision outranks is dropped now rather than left
	// for a bind-time check: the tombstone retention is bounded on its own,
	// so a tombstone may be forgotten while the parked copy remains.
	p.dropParkedIfOutrankedLocked(k, decidedAt)
	p.mu.Unlock()
}

// dropParkedIfOutrankedLocked discards the parked copy of a row whose
// evidence is not newer than a delete decided at decidedAt. Called with p.mu
// held.
func (p *Persister) dropParkedIfOutrankedLocked(k crs.HolderKey, decidedAt time.Time) {
	pk, ok := p.parkedBucket[k]
	if !ok {
		return
	}
	if rec, ok := p.pending[pk][k]; ok && !rec.UpdatedAt.After(decidedAt) {
		p.removeParkedLocked(pk, k)
		p.counters.droppedPending++
	}
}

// tombstonedLocked is Tombstoned with p.mu held.
func (p *Persister) tombstonedLocked(k crs.HolderKey, updatedAt time.Time) bool {
	// Ties go to the delete, as in MarkHolderUpsert.
	if decided, pending := p.holderDeletes[k]; pending && !updatedAt.After(decided) {
		return true
	}
	decided, ok := p.recentDeletes[k]
	return ok && !updatedAt.After(decided)
}

// Tombstoned reports whether a row whose evidence dates from updatedAt is
// outranked by a delete this run decided at or after that time: one still
// pending, in flight, or written within the last TTL. Such a row (loaded by
// a retried restore, or parked by an older session before the decision) must
// not bind.
func (p *Persister) Tombstoned(k crs.HolderKey, updatedAt time.Time) bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.tombstonedLocked(k, updatedAt)
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

// timedKey is one row identity with the time that orders it: a parked row's
// expiry, or a delete decision's time.
type timedKey struct {
	key crs.HolderKey
	at  time.Time
}

// keyedTimeHeap orders identities by time, soonest first, and indexes the
// entries by identity, so an entry moves when its time changes and leaves
// when its row leaves the set, in O(log n) each. It holds exactly one entry
// per key: nothing is ever stale, compacted or skipped, and a prune pops
// from the soonest end in bounded chunks.
type keyedTimeHeap struct {
	entries []timedKey
	pos     map[crs.HolderKey]int
}

func (h *keyedTimeHeap) Len() int           { return len(h.entries) }
func (h *keyedTimeHeap) Less(i, j int) bool { return h.entries[i].at.Before(h.entries[j].at) }
func (h *keyedTimeHeap) Swap(i, j int) {
	h.entries[i], h.entries[j] = h.entries[j], h.entries[i]
	h.pos[h.entries[i].key] = i
	h.pos[h.entries[j].key] = j
}
func (h *keyedTimeHeap) Push(x any) {
	e := x.(timedKey)
	h.pos[e.key] = len(h.entries)
	h.entries = append(h.entries, e)
}
func (h *keyedTimeHeap) Pop() any {
	old := h.entries
	n := len(old)
	e := old[n-1]
	old[n-1] = timedKey{}
	h.entries = old[:n-1]
	delete(h.pos, e.key)
	return e
}

// set records a key's time, moving its entry when it has one.
func (h *keyedTimeHeap) set(key crs.HolderKey, at time.Time) {
	if h.pos == nil {
		h.pos = make(map[crs.HolderKey]int)
	}
	if i, ok := h.pos[key]; ok {
		h.entries[i].at = at
		heap.Fix(h, i)
		return
	}
	heap.Push(h, timedKey{key: key, at: at})
}

// remove drops a key's entry, if it has one.
func (h *keyedTimeHeap) remove(key crs.HolderKey) {
	if i, ok := h.pos[key]; ok {
		heap.Remove(h, i)
	}
}

// soonest returns the entry with the earliest time.
func (h *keyedTimeHeap) soonest() (timedKey, bool) {
	if len(h.entries) == 0 {
		return timedKey{}, false
	}
	return h.entries[0], true
}

type batch struct {
	upserts  []crs.HolderRecord
	deletes  []crs.HolderKey
	deleteAt map[crs.HolderKey]time.Time
	demand   []crs.DemandRecord
	// overflowSeq is the overflow count the batch was drained under.
	overflowSeq uint64
}

func (p *Persister) drain() batch {
	p.mu.Lock()
	defer p.mu.Unlock()
	b := batch{
		upserts:     make([]crs.HolderRecord, 0, min(len(p.holderUpserts), HolderFlushRows)),
		deletes:     make([]crs.HolderKey, 0, min(len(p.holderDeletes), HolderFlushRows)),
		deleteAt:    make(map[crs.HolderKey]time.Time, min(len(p.holderDeletes), HolderFlushRows)),
		demand:      make([]crs.DemandRecord, 0, min(len(p.demandTouched), DemandFlushRows)),
		overflowSeq: p.overflowSeq,
	}
	for k, rec := range p.holderUpserts {
		if len(b.upserts) >= HolderFlushRows {
			break
		}
		b.upserts = append(b.upserts, rec)
		delete(p.holderUpserts, k)
	}
	for k, at := range p.holderDeletes {
		if len(b.deletes) >= HolderFlushRows {
			break
		}
		b.deletes = append(b.deletes, k)
		b.deleteAt[k] = at
		delete(p.holderDeletes, k)
		// Visible to Tombstoned from the moment the delete leaves the
		// dirty set, so a bind during the write's round trip cannot take a
		// parked copy the decision outranks; a failed write requeues the
		// delete and this entry stays.
		p.rememberDeleteLocked(k, at)
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

// requeue merges an unwritten remainder back so the next flush retries it:
// upserts and demand bounded by the dirty cap, deletes never dropped. Marks
// made meanwhile win.
func (p *Persister) requeue(b batch) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if b.overflowSeq != p.overflowSeq {
		// The batch was in flight when a backlog overflow released delete
		// decisions: an upsert in it may be evidence one of them condemned
		// (the queued copy is removed at decision time, the drained copy
		// was already out), and the reset that follows would write it back
		// to be restored later. None of them outranks a released decision
		// (a receipt newer than a decision cancels it before it can be
		// released), so they are dropped; the next receipt re-marks a row
		// that is still live.
		p.counters.droppedDirty += uint64(len(b.upserts))
		b.upserts = nil
	}
	for _, rec := range b.upserts {
		k := rec.HolderKey()
		if _, deleted := p.holderDeletes[k]; deleted {
			continue
		}
		if queued, present := p.holderUpserts[k]; present {
			// A mark made while the batch was in flight may be an older
			// delayed receipt: keep the newer evidence either way.
			p.holderUpserts[k] = crs.Later(queued, rec)
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
		// Never dropped at the cap, unlike an upsert: a delete lost here
		// would leave its durable row to be restored (the reason
		// MarkHolderDelete resets the copy instead of dropping), and the
		// batch was under the cap when it was drained, so the overshoot is
		// bounded by one flush batch.
		// Flush always carries the decision times through; a batch without
		// them would give a requeued delete a later decision, which rejects
		// receipts it should not and widens the tombstone's window.
		at, ok := b.deleteAt[k]
		if !ok {
			at = time.Now()
		}
		// The row may have been re-proved and invalidated again while the
		// write was failing: the later decision is the one that stands.
		if cur, present := p.holderDeletes[k]; present && cur.After(at) {
			at = cur
		}
		p.holderDeletes[k] = at
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
	if !p.Ready() {
		return nil
	}
	if err := p.resetIfPending(ctx); err != nil {
		return err
	}
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
		p.requeue(batch{upserts: b.upserts[wrote:], deletes: b.deletes[deleted:], deleteAt: b.deleteAt, demand: b.demand[demand:], overflowSeq: b.overflowSeq})
		p.logger.Warn("cache routing persistence flush failed; unwritten rows requeued", "error", err,
			"upserts_left", len(b.upserts)-wrote, "deletes_left", len(b.deletes)-deleted,
			"demand_left", len(b.demand)-demand)
	}
	return err
}

// FlushAll flushes repeatedly until nothing is dirty, an error occurs or the
// context ends. Used by the shutdown flush, after the HTTP server and the
// provider sockets are down and the periodic loop has been stopped.
func (p *Persister) FlushAll(ctx context.Context) error {
	if p == nil {
		return nil
	}
	if !p.Ready() {
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
func (p *Persister) Prune(ctx context.Context, now time.Time, ttl time.Duration) {
	if p == nil {
		return
	}
	// Parked rows are in-process state and expire whether or not the store
	// is reachable; dropping them never waits for the restore. A written
	// tombstone outranks older parked evidence for one TTL, after which any
	// such row has expired on its own. Both run in bounded chunks: a receipt
	// holding the tracker lock waits on p.mu, and requests on the tracker
	// lock.
	p.prunePendingChunked(now)
	p.forgetDecisionsChunked(now, ttl)
	if !p.Ready() {
		return
	}
	if _, err := p.store.PruneCacheRoutingState(ctx, now, ttl, now.Add(-ttl)); err != nil && ctx.Err() == nil {
		p.logger.Warn("cache routing persistence prune failed", "error", err)
	}
	p.mu.Lock()
	p.demandPersisted = make(map[string]time.Time)
	p.mu.Unlock()
}

// resetIfPending discards the durable copy when the delete backlog
// overflowed (MarkHolderDelete). Called with flushMu held once the key
// generation is established; a failed reset is retried by the next flush,
// and nothing is written before it succeeds, so no row a released delete
// condemned outlives the decision. Deletes marked after the overflow stay
// queued and are written afterwards (no-ops for rows the reset removed);
// an overflow during the reset itself releases only decisions against rows
// the reset removes or that were never written, so clearing the flag
// afterwards is safe.
func (p *Persister) resetIfPending(ctx context.Context) error {
	p.mu.Lock()
	pending := p.resetPending
	p.mu.Unlock()
	if !pending {
		return nil
	}
	started := time.Now()
	if err := p.store.ResetCacheRoutingState(ctx, p.fingerprint); err != nil {
		// A failed flush attempt, for the health counters.
		p.mu.Lock()
		p.counters.flushes++
		p.counters.flushErrors++
		p.counters.lastFlushMs = time.Since(started).Milliseconds()
		p.counters.lastFlushAt = time.Now()
		p.mu.Unlock()
		p.logger.Warn("cache routing persistence: the durable copy could not be reset after the delete backlog overflowed; retrying", "error", err)
		return err
	}
	p.logger.Warn("cache routing persistence: the delete backlog outgrew its budget during a store outage; the durable copy was reset and is rewritten from live evidence")
	p.mu.Lock()
	p.resetPending = false
	// The reset removed the demand rows too; the dedupe map must not
	// suppress their rewrite.
	p.demandPersisted = make(map[string]time.Time)
	p.mu.Unlock()
	return nil
}

// dirtyEmpty is for tests.
func (p *Persister) dirtyEmpty() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.holderUpserts) == 0 && len(p.holderDeletes) == 0 && len(p.demandTouched) == 0
}

// Ready reports whether Restore has established the key generation, which
// gates every write; the registry retries the restore until it has.
func (p *Persister) Ready() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.ready
}

// rememberDeleteLocked records a delete decision for Tombstoned, bounded by
// the holder budget: beyond the limit the oldest decisions are forgotten
// first, by decision time (the TTL bound is applied by Prune). A key decided
// again moves to its new time. Called with p.mu held.
func (p *Persister) rememberDeleteLocked(k crs.HolderKey, at time.Time) {
	if cur, present := p.recentDeletes[k]; present && !at.After(cur) {
		return
	}
	p.recentDeletes[k] = at
	p.recentOrder.set(k, at)
	for len(p.recentDeletes) > p.retentionLimit {
		oldest, ok := p.recentOrder.soonest()
		if !ok {
			break
		}
		p.forgetDecisionLocked(oldest.key)
	}
}

// forgetDecisionLocked removes one retained decision from the map and the
// order. Called with p.mu held.
func (p *Persister) forgetDecisionLocked(k crs.HolderKey) {
	delete(p.recentDeletes, k)
	p.recentOrder.remove(k)
}

// forgetDecisionsChunked forgets the delete decisions older than the TTL in
// bounded chunks, releasing p.mu between them, so a receipt holding the
// tracker lock (and behind it the request path) never waits behind a scan
// of the whole retention set.
func (p *Persister) forgetDecisionsChunked(now time.Time, ttl time.Duration) {
	for {
		p.mu.Lock()
		more := p.forgetDecisionsBatchLocked(now, ttl, pruneBatchRows)
		p.mu.Unlock()
		if !more {
			return
		}
	}
}

// forgetDecisionsBatchLocked forgets up to limit decisions older than the
// TTL (limit <= 0: no bound), oldest first, and reports whether older ones
// may remain. Called with p.mu held.
func (p *Persister) forgetDecisionsBatchLocked(now time.Time, ttl time.Duration, limit int) bool {
	forgotten := 0
	for {
		oldest, ok := p.recentOrder.soonest()
		if !ok || now.Sub(oldest.at) < ttl {
			return false
		}
		if limit > 0 && forgotten >= limit {
			return true
		}
		forgotten++
		p.forgetDecisionLocked(oldest.key)
	}
}
