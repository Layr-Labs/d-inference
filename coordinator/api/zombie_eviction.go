package api

import "container/list"

// Recency operations are constant-time under z.mu. The list stores only IDs;
// expired snapshots never retain links into the rest of the tracker.
func (z *zombieStreamCanceller) touchLocked(id string) {
	if z.positions == nil {
		z.positions = make(map[string]*list.Element)
	}
	if node := z.positions[id]; node != nil {
		z.recency.MoveToBack(node)
	} else {
		z.positions[id] = z.recency.PushBack(id)
	}
}

func (z *zombieStreamCanceller) removeLocked(id string) {
	delete(z.entries, id)
	if node := z.positions[id]; node != nil {
		z.recency.Remove(node)
		delete(z.positions, id)
	}
}

// Capped insertion evicts one least-recently-active entry without scanning.
// record/strayChunk already run the rate-limited TTL sweep; reaching the cap
// must not force an extra map walk on every unseen request or stray token.
func (z *zombieStreamCanceller) makeRoomLocked() []zombieEntry {
	if len(z.entries) < zombieCancelMaxEntries {
		return nil
	}
	id := z.recency.Front().Value.(string)
	expired := *z.entries[id]
	z.removeLocked(id)
	return []zombieEntry{expired}
}
