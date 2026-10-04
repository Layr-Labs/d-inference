package cachepersist

import (
	"context"
	"time"

	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Flush snapshots one bounded batch, writes outside the leaf lock and
// acknowledges successful chunks. Failed writes remain pending automatically.
// A reset blocks snapshots and interrupts older batches before their next
// store call. All flushes share one writer, including the shutdown flush.
func (p *Persister) Flush(ctx context.Context) (err error) {
	if p == nil {
		return nil
	}
	p.flushMu.Lock()
	defer p.flushMu.Unlock()
	if !p.Ready() {
		return nil
	}
	started, worked := time.Now(), false
	defer func() {
		if worked {
			p.recordFlush(started, err)
		}
	}()
	var b cachequeue.Batch
	for {
		if err = ctx.Err(); err != nil {
			return err
		}
		var reset bool
		b, reset = p.queue.Snapshot()
		if !reset {
			break
		}
		worked = true
		if err = p.resetDurableCopy(ctx); err != nil {
			return err
		}
	}
	if !b.Empty() {
		worked = true
		return p.writeBatch(ctx, b)
	}
	return nil
}

func (p *Persister) writeBatch(ctx context.Context, b cachequeue.Batch) error {
	// Check before every store call, including delete and demand chunks.
	// If an overflow lands during a write, that call may finish; the reset
	// removes its rows before the next chunk can proceed.
	for start := 0; start < len(b.Upserts); start += crs.BatchRows {
		if p.overflowedSince(b.OverflowSeq) {
			return p.resetDurableCopy(ctx)
		}
		chunk := b.Upserts[start:min(start+crs.BatchRows, len(b.Upserts))]
		rows := make([]crs.HolderRecord, len(chunk))
		for i, write := range chunk {
			rows[i] = write.Record
		}
		if err := p.store.UpsertCacheHolders(ctx, rows); err != nil {
			return err
		}
		p.acknowledgeHolders(chunk)
	}
	for start := 0; start < len(b.Deletes); start += crs.BatchRows {
		if p.overflowedSince(b.OverflowSeq) {
			return p.resetDurableCopy(ctx)
		}
		chunk := b.Deletes[start:min(start+crs.BatchRows, len(b.Deletes))]
		keys := make([]crs.HolderKey, len(chunk))
		for i, write := range chunk {
			keys[i] = write.Key
		}
		if err := p.store.DeleteCacheHolders(ctx, keys); err != nil {
			return err
		}
		p.acknowledgeHolders(chunk)
	}
	for start := 0; start < len(b.Demand); start += crs.BatchRows {
		if p.overflowedSince(b.OverflowSeq) {
			return p.resetDurableCopy(ctx)
		}
		chunk := b.Demand[start:min(start+crs.BatchRows, len(b.Demand))]
		rows := make([]crs.DemandRecord, len(chunk))
		for i, write := range chunk {
			rows[i] = crs.DemandRecord{Key: write.Key, SeenAt: write.SeenAt}
		}
		if err := p.store.UpsertCacheDemand(ctx, rows); err != nil {
			return err
		}
		p.acknowledgeDemand(chunk)
	}
	// An overflow during the last call still needs its reset in this flush.
	if p.overflowedSince(b.OverflowSeq) {
		return p.resetDurableCopy(ctx)
	}
	return nil
}

func (p *Persister) recordFlush(started time.Time, err error) {
	p.queue.Mu.Lock()
	p.queue.Counters.Flushes++
	p.queue.Counters.LastFlushMs = time.Since(started).Milliseconds()
	p.queue.Counters.LastFlushAt = time.Now()
	if err != nil {
		p.queue.Counters.FlushErrors++
	}
	p.queue.Mu.Unlock()
	if err != nil {
		p.logger.Warn("cache routing persistence flush failed; unwritten changes remain pending", "error", err)
	}
}

// FlushAll is bounded by ctx and finishes only when all work is acknowledged.
// Shutdown calls it after joining the producers and the periodic writer.
func (p *Persister) FlushAll(ctx context.Context) error {
	if p == nil || !p.Ready() {
		return nil
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := p.Flush(ctx); err != nil {
			return err
		}
		empty := p.queue.Empty()
		if empty {
			return nil
		}
	}
}
