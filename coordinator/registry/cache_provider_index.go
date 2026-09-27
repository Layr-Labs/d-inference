package registry

// The per-provider indexes make provider-scoped invalidation cost O(that
// provider's entries). Walking every bucket and attempt instead held the
// tracker lock for 14 to 24 ms at a full holder index
// (BenchmarkCacheProviderInvalidationWalk), and the callers hold the provider
// lock and the registry lock (ReplaceProviderModels the write lock) while
// they wait for it. The holder index costs 38 B per holder.
//
// Entries are the order-heap entries themselves, added where the heap pushes
// and dropped where it removes, so the two cannot disagree about membership.

func (t *cacheRoutingTracker) indexHolderLocked(entry *cacheHolderOrderEntry) {
	set := t.holdersByProvider[entry.ref.providerID]
	if set == nil {
		set = make(map[*cacheHolderOrderEntry]struct{})
		t.holdersByProvider[entry.ref.providerID] = set
	}
	set[entry] = struct{}{}
}

func (t *cacheRoutingTracker) unindexHolderLocked(entry *cacheHolderOrderEntry) {
	set := t.holdersByProvider[entry.ref.providerID]
	delete(set, entry)
	if len(set) == 0 {
		delete(t.holdersByProvider, entry.ref.providerID)
	}
}

func (t *cacheRoutingTracker) indexAttemptLocked(entry *cacheAttemptOrderEntry) {
	set := t.attemptsByProvider[entry.providerID]
	if set == nil {
		set = make(map[*cacheAttemptOrderEntry]struct{})
		t.attemptsByProvider[entry.providerID] = set
	}
	set[entry] = struct{}{}
}

func (t *cacheRoutingTracker) unindexAttemptLocked(entry *cacheAttemptOrderEntry) {
	set := t.attemptsByProvider[entry.providerID]
	delete(set, entry)
	if len(set) == 0 {
		delete(t.attemptsByProvider, entry.providerID)
	}
}
