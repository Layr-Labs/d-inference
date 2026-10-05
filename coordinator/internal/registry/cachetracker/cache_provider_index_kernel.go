package cachetracker

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
)

func (t *Tracker[P]) IndexHolderLocked(entry *cacheindex.Entry[cacheindex.HolderRef]) {
	t.holdersByProvider.Store(entry.Key().ProviderID, entry)
}

func (t *Tracker[P]) UnindexHolderLocked(entry *cacheindex.Entry[cacheindex.HolderRef]) {
	t.holdersByProvider.Delete(entry.Key().ProviderID, entry)
}

func (t *Tracker[P]) IndexAttemptLocked(entry *cacheindex.Entry[cacheindex.AttemptRef]) {
	t.attemptsByProvider.Store(entry.Key().ProviderID, entry)
}

func (t *Tracker[P]) UnindexAttemptLocked(entry *cacheindex.Entry[cacheindex.AttemptRef]) {
	t.attemptsByProvider.Delete(entry.Key().ProviderID, entry)
}
