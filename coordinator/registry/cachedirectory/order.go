package cachedirectory

import (
	"time"
)

type cacheAttemptOrderEntry struct {
	nonce     string
	createdAt time.Time
	index     int
}

type cacheAttemptOrderHeap []*cacheAttemptOrderEntry

func (h cacheAttemptOrderHeap) Len() int { return len(h) }

func (h cacheAttemptOrderHeap) Less(i, j int) bool {
	if h[i].createdAt.Equal(h[j].createdAt) {
		return h[i].nonce < h[j].nonce
	}
	return h[i].createdAt.Before(h[j].createdAt)
}

func (h cacheAttemptOrderHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}

func (h *cacheAttemptOrderHeap) Push(value any) {
	entry := value.(*cacheAttemptOrderEntry)
	entry.index = len(*h)
	*h = append(*h, entry)
}

func (h *cacheAttemptOrderHeap) Pop() any {
	old := *h
	last := len(old) - 1
	entry := old[last]
	old[last] = nil
	entry.index = -1
	*h = old[:last]
	return entry
}

type cacheHolderRef struct {
	key        string
	providerID string
}

type cacheHolderOrderEntry struct {
	ref       cacheHolderRef
	updatedAt time.Time
	index     int
}

type cacheHolderOrderHeap []*cacheHolderOrderEntry

func (h cacheHolderOrderHeap) Len() int { return len(h) }

func (h cacheHolderOrderHeap) Less(i, j int) bool {
	if !h[i].updatedAt.Equal(h[j].updatedAt) {
		return h[i].updatedAt.Before(h[j].updatedAt)
	}
	if h[i].ref.key != h[j].ref.key {
		return h[i].ref.key < h[j].ref.key
	}
	return h[i].ref.providerID < h[j].ref.providerID
}

func (h cacheHolderOrderHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}

func (h *cacheHolderOrderHeap) Push(value any) {
	entry := value.(*cacheHolderOrderEntry)
	entry.index = len(*h)
	*h = append(*h, entry)
}

func (h *cacheHolderOrderHeap) Pop() any {
	old := *h
	last := len(old) - 1
	entry := old[last]
	old[last] = nil
	entry.index = -1
	*h = old[:last]
	return entry
}
