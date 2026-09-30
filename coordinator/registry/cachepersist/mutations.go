package cachepersist

import (
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

type holderChange struct {
	record   crs.HolderRecord
	revision uint64
}

type deleteChange struct {
	deletedAt time.Time
	revision  uint64
}

type demandChange struct {
	seenAt   time.Time
	revision uint64
}

type holderWrite struct {
	key crs.HolderKey
	holderChange
	deleted   bool
	deletedAt time.Time
}

type demandWrite struct {
	key string
	demandChange
}

type batch struct {
	upserts     []holderWrite
	deletes     []holderWrite
	demand      []demandWrite
	overflowSeq uint64
}

func (b batch) empty() bool {
	return len(b.upserts)+len(b.deletes)+len(b.demand) == 0
}

// snapshot copies bounded work without removing it. A pending reset blocks
// the snapshot atomically; failures leave work untouched and successful
// chunks acknowledge only the revisions actually written.
func (p *Persister) snapshot() (batch, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.resetPending {
		return batch{}, true
	}
	b := batch{
		upserts:     make([]holderWrite, 0, min(len(p.holderUpserts), HolderFlushRows)),
		deletes:     make([]holderWrite, 0, min(len(p.holderDeletes), HolderFlushRows)),
		demand:      make([]demandWrite, 0, min(len(p.demandTouched), DemandFlushRows)),
		overflowSeq: p.overflowSeq,
	}
	for k, change := range p.holderUpserts {
		if len(b.upserts) == HolderFlushRows {
			break
		}
		b.upserts = append(b.upserts, holderWrite{key: k, holderChange: change})
	}
	for k, change := range p.holderDeletes {
		if len(b.deletes) == HolderFlushRows {
			break
		}
		b.deletes = append(b.deletes, holderWrite{key: k, deleted: true, deletedAt: change.deletedAt, holderChange: holderChange{revision: change.revision}})
	}
	for key, change := range p.demandTouched {
		if len(b.demand) == DemandFlushRows {
			break
		}
		b.demand = append(b.demand, demandWrite{key: key, demandChange: change})
	}
	return b, false
}

// holderRevisionLocked finds the desired mutation, regardless of write kind.
func (p *Persister) holderRevisionLocked(k crs.HolderKey) (uint64, bool) {
	if change, exists := p.holderDeletes[k]; exists {
		return change.revision, true
	}
	change, exists := p.holderUpserts[k]
	return change.revision, exists
}

func (p *Persister) acknowledgeHolders(writes []holderWrite) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, write := range writes {
		if write.deleted {
			p.rememberDeleteLocked(write.key, write.deletedAt)
			p.counters.rowsDeleted++
		} else {
			p.counters.rowsWritten++
		}
		if revision, exists := p.holderRevisionLocked(write.key); exists && revision == write.revision {
			delete(p.holderUpserts, write.key)
			delete(p.holderDeletes, write.key)
		}
	}
}

func (p *Persister) acknowledgeDemand(writes []demandWrite) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, write := range writes {
		if write.seenAt.After(p.demandPersisted[write.key]) {
			p.demandPersisted[write.key] = write.seenAt
		}
		if current, exists := p.demandTouched[write.key]; exists && current.revision == write.revision {
			delete(p.demandTouched, write.key)
		}
		p.counters.rowsWritten++
	}
}
