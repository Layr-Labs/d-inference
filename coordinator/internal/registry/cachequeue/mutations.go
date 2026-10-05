package cachequeue

import (
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

type HolderChange struct {
	Record   crs.HolderRecord
	Revision uint64
}

type DeleteChange struct {
	DeletedAt time.Time
	Revision  uint64
}

type DemandChange struct {
	SeenAt   time.Time
	Revision uint64
}

type HolderWrite struct {
	Key crs.HolderKey
	HolderChange
	Deleted   bool
	DeletedAt time.Time
}

type DemandWrite struct {
	Key string
	DemandChange
}

type Batch struct {
	Upserts     []HolderWrite
	Deletes     []HolderWrite
	Demand      []DemandWrite
	OverflowSeq uint64
}

func (b Batch) Empty() bool {
	return len(b.Upserts)+len(b.Deletes)+len(b.Demand) == 0
}

// Snapshot copies bounded work without removing it. A pending reset blocks
// the snapshot atomically; failures leave work untouched and successful
// chunks acknowledge only the revisions actually written.
func (p *Queue) Snapshot() (Batch, bool) {
	p.Mu.Lock()
	defer p.Mu.Unlock()
	if p.ResetPending {
		return Batch{}, true
	}
	b := Batch{
		Upserts:     make([]HolderWrite, 0, min(len(p.HolderUpserts), HolderFlushRows)),
		Deletes:     make([]HolderWrite, 0, min(len(p.HolderDeletes), HolderFlushRows)),
		Demand:      make([]DemandWrite, 0, min(len(p.DemandTouched), DemandFlushRows)),
		OverflowSeq: p.OverflowSeq,
	}
	for k, change := range p.HolderUpserts {
		if len(b.Upserts) == HolderFlushRows {
			break
		}
		b.Upserts = append(b.Upserts, HolderWrite{Key: k, HolderChange: change})
	}
	for k, change := range p.HolderDeletes {
		if len(b.Deletes) == HolderFlushRows {
			break
		}
		b.Deletes = append(b.Deletes, HolderWrite{Key: k, Deleted: true, DeletedAt: change.DeletedAt, HolderChange: HolderChange{Revision: change.Revision}})
	}
	for key, change := range p.DemandTouched {
		if len(b.Demand) == DemandFlushRows {
			break
		}
		b.Demand = append(b.Demand, DemandWrite{Key: key, DemandChange: change})
	}
	return b, false
}

// Empty reports whether a shutdown flush has acknowledged every mutation.
func (p *Queue) Empty() bool {
	p.Mu.Lock()
	defer p.Mu.Unlock()
	return len(p.HolderUpserts)+len(p.HolderDeletes)+len(p.DemandTouched) == 0 && !p.ResetPending
}
