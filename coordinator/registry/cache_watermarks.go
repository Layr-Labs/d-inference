package registry

import (
	"container/heap"
	"time"
)

type cacheActiveAttemptRefEntry struct {
	nonce    string
	sequence uint64
	index    int
}

type cacheActiveAttemptRefHeap []*cacheActiveAttemptRefEntry

func (h cacheActiveAttemptRefHeap) Len() int { return len(h) }
func (h cacheActiveAttemptRefHeap) Less(i, j int) bool {
	if h[i].sequence != h[j].sequence {
		return h[i].sequence < h[j].sequence
	}
	return h[i].nonce < h[j].nonce
}
func (h cacheActiveAttemptRefHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}
func (h *cacheActiveAttemptRefHeap) Push(value any) {
	entry := value.(*cacheActiveAttemptRefEntry)
	entry.index = len(*h)
	*h = append(*h, entry)
}
func (h *cacheActiveAttemptRefHeap) Pop() any {
	old := *h
	last := len(old) - 1
	entry := old[last]
	old[last] = nil
	entry.index = -1
	*h = old[:last]
	return entry
}

type cacheActiveAttemptRefState struct {
	order   cacheActiveAttemptRefHeap
	byNonce map[string]*cacheActiveAttemptRefEntry
}

func cacheAttemptHolderRefs(attempt cacheAttempt) []cacheHolderRef {
	refs := make([]cacheHolderRef, 0, 2)
	if attempt.ExactKey != "" {
		refs = append(refs, cacheHolderRef{key: attempt.ExactKey, providerID: attempt.ProviderID})
	}
	if attempt.ConversationKey != "" && attempt.ConversationKey != attempt.ExactKey {
		refs = append(refs, cacheHolderRef{key: attempt.ConversationKey, providerID: attempt.ProviderID})
	}
	return refs
}

func (t *cacheRoutingTracker) addActiveAttemptRefsLocked(nonce string, attempt cacheAttempt) {
	for _, ref := range cacheAttemptHolderRefs(attempt) {
		state := t.activeAttemptRefs[ref]
		if state == nil {
			state = &cacheActiveAttemptRefState{byNonce: make(map[string]*cacheActiveAttemptRefEntry)}
			t.activeAttemptRefs[ref] = state
		}
		entry := &cacheActiveAttemptRefEntry{nonce: nonce, sequence: attempt.Sequence}
		heap.Push(&state.order, entry)
		state.byNonce[nonce] = entry
		t.syncWatermarkEvictabilityLocked(ref)
	}
}

func (t *cacheRoutingTracker) removeActiveAttemptRefsLocked(nonce string, attempt cacheAttempt) {
	for _, ref := range cacheAttemptHolderRefs(attempt) {
		state := t.activeAttemptRefs[ref]
		if state == nil {
			continue
		}
		if entry := state.byNonce[nonce]; entry != nil {
			heap.Remove(&state.order, entry.index)
			delete(state.byNonce, nonce)
		}
		if len(state.order) == 0 {
			delete(t.activeAttemptRefs, ref)
		}
		t.syncWatermarkEvictabilityLocked(ref)
	}
	t.enforceWatermarkCapLocked()
}

func (t *cacheRoutingTracker) watermarkProtectedLocked(ref cacheHolderRef, sequence uint64) bool {
	state := t.activeAttemptRefs[ref]
	return state != nil && len(state.order) > 0 && state.order[0].sequence < sequence
}

func (t *cacheRoutingTracker) syncWatermarkEvictabilityLocked(ref cacheHolderRef) {
	watermark, exists := t.watermarks[ref]
	entry := t.watermarkOrderByRef[ref]
	if !exists || t.watermarkProtectedLocked(ref, watermark.Sequence) {
		if entry != nil {
			heap.Remove(&t.watermarkOrder, entry.index)
			delete(t.watermarkOrderByRef, ref)
		}
		return
	}
	if entry != nil {
		entry.updatedAt = watermark.UpdatedAt
		heap.Fix(&t.watermarkOrder, entry.index)
		return
	}
	entry = &cacheWatermarkOrderEntry{ref: ref, updatedAt: watermark.UpdatedAt}
	heap.Push(&t.watermarkOrder, entry)
	t.watermarkOrderByRef[ref] = entry
}

// activeWatermarkLocked returns the live sequence watermark for one route and
// provider. Watermarks outlive holders so delayed positive receipts cannot
// resurrect evidence invalidated by a newer miss or capacity result.
func (t *cacheRoutingTracker) activeWatermarkLocked(ref cacheHolderRef, now time.Time) (cacheEvidenceWatermark, bool) {
	watermark, ok := t.watermarks[ref]
	if !ok {
		return cacheEvidenceWatermark{}, false
	}
	if now.Before(watermark.ExpiresAt) {
		return watermark, true
	}
	t.removeWatermarkLocked(ref)
	return cacheEvidenceWatermark{}, false
}

func (t *cacheRoutingTracker) advanceWatermarkLocked(ref cacheHolderRef, sequence uint64, now time.Time) {
	if ref.key == "" || ref.providerID == "" || sequence == 0 {
		return
	}
	watermark, ok := t.activeWatermarkLocked(ref, now)
	if ok && sequence < watermark.Sequence {
		return
	}
	if sequence > watermark.Sequence {
		watermark.Sequence = sequence
	}
	watermark.UpdatedAt = now
	watermarkTTL := t.ttl
	if watermarkTTL < cacheRoutingInFlightAttemptTTL {
		watermarkTTL = cacheRoutingInFlightAttemptTTL
	}
	watermark.ExpiresAt = now.Add(watermarkTTL)
	t.watermarks[ref] = watermark
	t.syncWatermarkEvictabilityLocked(ref)
	t.enforceWatermarkCapLocked()
}

func (t *cacheRoutingTracker) removeWatermarkLocked(ref cacheHolderRef) {
	delete(t.watermarks, ref)
	if entry := t.watermarkOrderByRef[ref]; entry != nil {
		heap.Remove(&t.watermarkOrder, entry.index)
		delete(t.watermarkOrderByRef, ref)
	}
}

// enforceWatermarkCapLocked evicts the oldest unprotected watermark in O(log n).
// activeAttemptRefs keeps protected refs out of watermarkOrder, so completed
// tombstone churn cannot evict ordering evidence needed by a delayed receipt.
func (t *cacheRoutingTracker) enforceWatermarkCapLocked() {
	for len(t.watermarks) > t.maxWatermarks {
		if len(t.watermarkOrder) == 0 {
			// Defensive only: the 2*maxAttempts sizing invariant makes this
			// unreachable while attempt and route-key caps hold.
			return
		}
		t.removeWatermarkLocked(t.watermarkOrder[0].ref)
	}
}
