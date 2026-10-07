package cancellation

import "container/list"

// zombieIndex is an insertion/recency index. The tracker serializes access;
// callers retaining an injected index must not access it during tracker calls.
// Each keyed node owns its entry and list handle, so removal cannot leave a
// second keyed index behind.
type Index struct {
	items map[string]*list.Element
	order list.List
}

type zombieNode struct {
	id    string
	entry *Entry
}

func (x *Index) Lookup(id string) *Entry {
	if x == nil || x.items[id] == nil {
		return nil
	}
	return x.items[id].Value.(zombieNode).entry
}

func (x *Index) Len() int {
	if x == nil {
		return 0
	}
	return x.order.Len()
}

func (x *Index) Oldest() (string, *Entry) {
	if x == nil || x.order.Front() == nil {
		return "", nil
	}
	n := x.order.Front().Value.(zombieNode)
	return n.id, n.entry
}

func (x *Index) Insert(id string, entry *Entry) {
	if x.items == nil {
		x.items = make(map[string]*list.Element)
	}
	if node := x.items[id]; node != nil {
		node.Value = zombieNode{id, entry}
		x.order.MoveToBack(node)
		return
	}
	x.items[id] = x.order.PushBack(zombieNode{id, entry})
}

func (x *Index) Touch(id string) {
	if x != nil {
		if node := x.items[id]; node != nil {
			x.order.MoveToBack(node)
		}
	}
}

func (x *Index) Remove(id string) {
	if x != nil {
		if node := x.items[id]; node != nil {
			x.order.Remove(node)
			delete(x.items, id)
		}
	}
}

// Capped insertion evicts one least-recently-active entry without scanning.
// record/strayChunk already run the rate-limited TTL sweep; reaching the cap
// must not force an extra map walk on every unseen request or stray token.
func (z *Tracker) makeRoomLocked() []Entry {
	if z.entries.Len() < MaxEntries {
		return nil
	}
	id, entry := z.entries.Oldest()
	Expired := *entry
	z.entries.Remove(id)
	return []Entry{Expired}
}
