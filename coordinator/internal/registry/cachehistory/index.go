// Package cachehistory owns the keyed arrival order used by cache demand.
package cachehistory

import (
	"container/list"
	"sync"
	"time"
)

type Entry struct {
	Key  string
	Seen time.Time
}

// Index keeps its key directory and arrival order private. Snapshots detach
// records for restore merging; they cannot mutate a live entry or list link.
type Index struct {
	mu      sync.Mutex
	order   list.List
	entries map[string]*list.Element
}

func New() *Index { return &Index{entries: make(map[string]*list.Element)} }

func (i *Index) Load(key string) (Entry, bool) {
	i.mu.Lock()
	defer i.mu.Unlock()
	e := i.entries[key]
	if e == nil {
		return Entry{}, false
	}
	return e.Value.(Entry), true
}

func (i *Index) Front() (Entry, bool) {
	i.mu.Lock()
	defer i.mu.Unlock()
	e := i.order.Front()
	if e == nil {
		return Entry{}, false
	}
	return e.Value.(Entry), true
}

func (i *Index) Store(entry Entry) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if e := i.entries[entry.Key]; e != nil {
		e.Value = entry
		i.order.MoveToBack(e)
	} else {
		i.entries[entry.Key] = i.order.PushBack(entry)
	}
}

func (i *Index) Delete(key string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if e := i.entries[key]; e != nil {
		delete(i.entries, key)
		i.order.Remove(e)
	}
}

func (i *Index) Len() int {
	i.mu.Lock()
	defer i.mu.Unlock()
	return len(i.entries)
}

func (i *Index) Snapshot() []Entry {
	i.mu.Lock()
	defer i.mu.Unlock()
	entries := make([]Entry, 0, i.order.Len())
	for e := i.order.Front(); e != nil; e = e.Next() {
		entries = append(entries, e.Value.(Entry))
	}
	return entries
}

func (i *Index) Reset(entries []Entry) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.order.Init()
	i.entries = make(map[string]*list.Element, len(entries))
	for _, entry := range entries {
		if e := i.entries[entry.Key]; e != nil {
			e.Value = entry
			i.order.MoveToBack(e)
		} else {
			i.entries[entry.Key] = i.order.PushBack(entry)
		}
	}
}
