package providerwire

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Accounting counts authorized inference handoffs for one logical request.
// Prepared or rejected frames cannot inflate its client-visible exhaustion count.
type Accounting struct{ committed int }

func (a *Accounting) Commit()    { a.committed++ }
func (a *Accounting) Count() int { return a.committed }

func (a *Accounting) ExhaustionCount(attempt int) int {
	if a.Count() > 0 {
		return a.Count()
	}
	return attempt + 1
}

func (a *Accounting) WriteQueued(ctx context.Context, provider *registry.Provider, pending *registry.PendingRequest, builder registry.TextFrameBuilder) (registry.TextFrameWriteMetadata, error) {
	return WriteDeferred(ctx, provider, pending, builder, func(metadata registry.TextFrameWriteMetadata) {
		a.Commit()
		pending.Profile.MarkAt(registry.StampWriteDequeued, metadata.DequeuedAt)
	})
}
