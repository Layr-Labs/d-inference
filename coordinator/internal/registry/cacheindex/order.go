// Package cacheindex owns the expiry and provider directories of cache evidence.
// Its operations are serialized by the receipt tracker's existing lock.
package cacheindex

import (
	"container/heap"
	"iter"
	"time"
)

type HolderRef struct {
	Key        string
	ProviderID string
}

type AttemptRef struct {
	Nonce      string
	ProviderID string
}

// Entry identity is stable across expiry refreshes and shared by the expiry,
// keyed and provider directories. Only Order can move or retime it.
type Entry[K comparable] struct {
	key       K
	expiresAt time.Time
	index     int
}

func (e *Entry[K]) Key() K               { return e.key }
func (e *Entry[K]) ExpiresAt() time.Time { return e.expiresAt }
func (e *Entry[K]) Position() int        { return e.index }

type expiryHeap[K comparable] struct {
	entries []*Entry[K]
	lessKey func(K, K) bool
}

func (h expiryHeap[K]) Len() int { return len(h.entries) }
func (h expiryHeap[K]) Less(i, j int) bool {
	a, b := h.entries[i], h.entries[j]
	if !a.expiresAt.Equal(b.expiresAt) {
		return a.expiresAt.Before(b.expiresAt)
	}
	return h.lessKey(a.key, b.key)
}
func (h expiryHeap[K]) Swap(i, j int) {
	h.entries[i], h.entries[j] = h.entries[j], h.entries[i]
	h.entries[i].index, h.entries[j].index = i, j
}
func (h *expiryHeap[K]) Push(value any) {
	entry := value.(*Entry[K])
	entry.index = len(h.entries)
	h.entries = append(h.entries, entry)
}
func (h *expiryHeap[K]) Pop() any {
	last := len(h.entries) - 1
	entry := h.entries[last]
	h.entries[last] = nil
	entry.index = -1
	h.entries = h.entries[:last]
	return entry
}

type Order[K, ID comparable] struct {
	heap  expiryHeap[K]
	byKey map[ID]*Entry[K]
}

func NewOrder[K, ID comparable](lessKey func(K, K) bool) *Order[K, ID] {
	return &Order[K, ID]{heap: expiryHeap[K]{lessKey: lessKey}, byKey: make(map[ID]*Entry[K])}
}

func NewHolderOrder() *Order[HolderRef, HolderRef] {
	return NewOrder[HolderRef, HolderRef](func(a, b HolderRef) bool {
		if a.Key != b.Key {
			return a.Key < b.Key
		}
		return a.ProviderID < b.ProviderID
	})
}

func NewAttemptOrder() *Order[AttemptRef, string] {
	return NewOrder[AttemptRef, string](func(a, b AttemptRef) bool { return a.Nonce < b.Nonce })
}

func (o *Order[K, ID]) Len() int             { return o.heap.Len() }
func (o *Order[K, ID]) KeyCount() int        { return len(o.byKey) }
func (o *Order[K, ID]) Load(id ID) *Entry[K] { return o.byKey[id] }
func (o *Order[K, ID]) Head() *Entry[K] {
	if o.Len() == 0 {
		return nil
	}
	return o.heap.entries[0]
}

// Track refreshes in place, including movement in either heap direction.
func (o *Order[K, ID]) Track(id ID, key K, expiresAt time.Time) *Entry[K] {
	if entry := o.byKey[id]; entry != nil {
		entry.key, entry.expiresAt = key, expiresAt
		heap.Fix(&o.heap, entry.Position())
		return entry
	}
	entry := &Entry[K]{key: key, expiresAt: expiresAt}
	heap.Push(&o.heap, entry)
	o.byKey[id] = entry
	return entry
}

func (o *Order[K, ID]) Remove(id ID) *Entry[K] {
	entry := o.byKey[id]
	if entry != nil {
		heap.Remove(&o.heap, entry.Position())
		delete(o.byKey, id)
	}
	return entry
}

func (o *Order[K, ID]) Less(i, j int) bool { return o.heap.Less(i, j) }
func (o *Order[K, ID]) Entries() iter.Seq2[int, *Entry[K]] {
	return func(yield func(int, *Entry[K]) bool) {
		for i, entry := range o.heap.entries {
			if !yield(i, entry) {
				return
			}
		}
	}
}

// Reset releases backing storage, not just membership, on generation retirement.
func (o *Order[K, ID]) Reset() {
	o.heap.entries, o.byKey = nil, nil
}
