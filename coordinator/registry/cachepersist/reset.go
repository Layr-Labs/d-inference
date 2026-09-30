package cachepersist

import (
	"context"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// requireResetLocked replaces the holder backlog in O(1). The durable reset
// subsumes its deletes. The timestamp cutoff rejects older evidence, even
// when marked after the overflow or taken from a parked bucket. Losing
// unrelated old hints here costs hit rate; restoring invalidated ones would
// violate the deletion fence.
func (p *Persister) requireResetLocked() {
	p.resetPending = true
	p.overflowSeq++
	p.discardBefore = p.deleteHighWater
	p.counters.overflowResets++
	p.counters.droppedDirty += uint64(len(p.holderUpserts))
	p.holderUpserts = make(map[crs.HolderKey]holderChange)
	p.holderDeletes = make(map[crs.HolderKey]deleteChange)
	select {
	case p.resetWake <- struct{}{}:
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
	p.mu.Lock()
	p.resetPending = false
	p.demandPersisted = make(map[string]time.Time)
	p.mu.Unlock()
	p.logger.Warn("cache routing persistence backlog overflowed; durable state reset and older evidence fenced")
	return nil
}

func (p *Persister) overflowedSince(seq uint64) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.overflowSeq != seq
}
