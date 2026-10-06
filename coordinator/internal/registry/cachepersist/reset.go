package cachepersist

import (
	"context"
	"time"

	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// requireResetLocked replaces the holder backlog in O(1). The durable reset
// subsumes its deletes. The timestamp cutoff rejects older evidence, even
// when marked after the overflow or taken from a parked bucket. Losing
// unrelated old hints here costs hit rate; restoring invalidated ones would
// violate the deletion fence.
func (p *Persister) requireResetLocked() {
	p.queue.ResetPending = true
	p.queue.OverflowSeq++
	p.queue.DiscardBefore = p.queue.DeleteHighWater
	p.queue.Counters.OverflowResets++
	p.queue.Counters.DroppedDirty += uint64(len(p.queue.HolderUpserts))
	p.queue.HolderUpserts = make(map[crs.HolderKey]cachequeue.HolderChange)
	p.queue.HolderDeletes = make(map[crs.HolderKey]cachequeue.DeleteChange)
	select {
	case p.queue.ResetWake <- struct{}{}:
	default:
	}
}

// resetDurableCopy runs under flushMu after a snapshot observed a pending
// reset. No flush writes during it, so another overflow is covered too.
// Fresh mutations stay pending; the cutoff remains after reset success.
func (p *Persister) resetDurableCopy(ctx context.Context) error {
	if err := p.store.ResetCacheRoutingState(ctx, p.fingerprint); err != nil {
		p.logger.Warn("cache routing persistence reset failed; retrying before further writes", "error", err)
		return err
	}
	p.queue.Mu.Lock()
	p.queue.ResetPending = false
	p.queue.DemandPersisted = make(map[string]time.Time)
	p.queue.Mu.Unlock()
	p.logger.Warn("cache routing persistence backlog overflowed; durable state reset and older evidence fenced")
	return nil
}

func (p *Persister) overflowedSince(seq uint64) bool {
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	return p.queue.OverflowSeq != seq
}
