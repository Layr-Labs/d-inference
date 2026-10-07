package cachepersist

import (
	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// holderRevisionLocked finds the desired mutation, regardless of write kind.
func (p *Persister) holderRevisionLocked(k crs.HolderKey) (uint64, bool) {
	if change, exists := p.queue.HolderDeletes[k]; exists {
		return change.Revision, true
	}
	change, exists := p.queue.HolderUpserts[k]
	return change.Revision, exists
}

func (p *Persister) acknowledgeHolders(writes []cachequeue.HolderWrite) {
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	for _, write := range writes {
		if write.Deleted {
			p.rememberDeleteLocked(write.Key, write.DeletedAt)
			p.queue.Counters.RowsDeleted++
		} else {
			p.queue.Counters.RowsWritten++
		}
		if revision, exists := p.holderRevisionLocked(write.Key); exists && revision == write.Revision {
			delete(p.queue.HolderUpserts, write.Key)
			delete(p.queue.HolderDeletes, write.Key)
		}
	}
}

func (p *Persister) acknowledgeDemand(writes []cachequeue.DemandWrite) {
	p.queue.Mu.Lock()
	defer p.queue.Mu.Unlock()
	for _, write := range writes {
		if write.SeenAt.After(p.queue.DemandPersisted[write.Key]) {
			p.queue.DemandPersisted[write.Key] = write.SeenAt
		}
		if current, exists := p.queue.DemandTouched[write.Key]; exists && current.Revision == write.Revision {
			delete(p.queue.DemandTouched, write.Key)
		}
		p.queue.Counters.RowsWritten++
	}
}
