package cacheindex

import "iter"

// Holders groups content-addressed records by connection identity. Its count
// is maintained with the primary directory, independently of the expiry order.
// The tracker serializes these operations with its existing receipt lock.
type Holders[V any] struct {
	buckets map[string]map[string]V
	count   int
}

func NewHolders[V any]() *Holders[V] {
	return &Holders[V]{buckets: make(map[string]map[string]V)}
}

func (h *Holders[V]) Len() int             { return h.count }
func (h *Holders[V]) BucketCount() int     { return len(h.buckets) }
func (h *Holders[V]) Count(key string) int { return len(h.buckets[key]) }
func (h *Holders[V]) Load(ref HolderRef) (V, bool) {
	value, present := h.buckets[ref.Key][ref.ProviderID]
	return value, present
}
func (h *Holders[V]) Lookup(ref HolderRef) V {
	value, _ := h.Load(ref)
	return value
}

// Bucket is an operational cursor, not a backing-map view. Reads remain values
// and the owning tracker retains serialization across coupled directory writes.
type Bucket[V any] struct {
	directory *Holders[V]
	key       string
}

func (h *Holders[V]) Bucket(key string) Bucket[V] { return Bucket[V]{directory: h, key: key} }
func (b Bucket[V]) Count() int                    { return b.directory.Count(b.key) }
func (b Bucket[V]) Lookup(providerID string) V {
	return b.directory.Lookup(HolderRef{Key: b.key, ProviderID: providerID})
}
func (b Bucket[V]) Load(providerID string) (V, bool) {
	return b.directory.Load(HolderRef{Key: b.key, ProviderID: providerID})
}
func (b Bucket[V]) Store(providerID string, value V) bool {
	return b.directory.Store(HolderRef{Key: b.key, ProviderID: providerID}, value)
}
func (b Bucket[V]) Entries() iter.Seq2[string, V] { return b.directory.Entries(b.key) }
func (h *Holders[V]) Buckets() iter.Seq2[string, Bucket[V]] {
	return func(yield func(string, Bucket[V]) bool) {
		for key := range h.buckets {
			if !yield(key, h.Bucket(key)) {
				return
			}
		}
	}
}
func (h *Holders[V]) Store(ref HolderRef, value V) bool {
	bucket := h.buckets[ref.Key]
	if bucket == nil {
		bucket = make(map[string]V)
		h.buckets[ref.Key] = bucket
	}
	_, present := bucket[ref.ProviderID]
	if !present {
		h.count++
	}
	bucket[ref.ProviderID] = value
	return !present
}
func (h *Holders[V]) Delete(ref HolderRef) (V, bool) {
	bucket := h.buckets[ref.Key]
	value, present := bucket[ref.ProviderID]
	if present {
		delete(bucket, ref.ProviderID)
		h.count--
	}
	if bucket != nil && len(bucket) == 0 {
		delete(h.buckets, ref.Key)
	}
	return value, present
}
func (h *Holders[V]) Keys() iter.Seq[string] {
	return func(yield func(string) bool) {
		for key := range h.buckets {
			if !yield(key) {
				return
			}
		}
	}
}
func (h *Holders[V]) Entries(key string) iter.Seq2[string, V] {
	return func(yield func(string, V) bool) {
		for providerID, value := range h.buckets[key] {
			if !yield(providerID, value) {
				return
			}
		}
	}
}
func (h *Holders[V]) Reset() { h.buckets, h.count = nil, 0 }

// Records is the primary directory for receipt attempts and capability-scoped
// sequence/fence records. It does not expose its backing map or a mutable view.
type Records[K comparable, V any] struct{ entries map[K]V }

func NewRecords[K comparable, V any]() *Records[K, V] {
	return &Records[K, V]{entries: make(map[K]V)}
}
func (r *Records[K, V]) Len() int { return len(r.entries) }
func (r *Records[K, V]) Load(key K) (V, bool) {
	value, present := r.entries[key]
	return value, present
}
func (r *Records[K, V]) Lookup(key K) V {
	value, _ := r.Load(key)
	return value
}
func (r *Records[K, V]) Store(key K, value V) { r.entries[key] = value }
func (r *Records[K, V]) Delete(key K)         { delete(r.entries, key) }
func (r *Records[K, V]) Entries() iter.Seq2[K, V] {
	return func(yield func(K, V) bool) {
		for key, value := range r.entries {
			if !yield(key, value) {
				return
			}
		}
	}
}
func (r *Records[K, V]) Reset() { r.entries = nil }
