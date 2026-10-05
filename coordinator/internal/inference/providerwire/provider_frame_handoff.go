package providerwire

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func WriteDeferred(
	ctx context.Context,
	provider *registry.Provider,
	pending *registry.PendingRequest,
	builder registry.TextFrameBuilder,
	onCommitted registry.TextFrameHandoff,
) (registry.TextFrameWriteMetadata, error) {
	if provider == nil || provider.Conn == nil {
		return registry.TextFrameWriteMetadata{}, errors.New("provider websocket is not connected")
	}
	metadata, err := provider.WriteInferenceTextDeferred(ctx, pending, builder, func(prepared registry.TextFrameWriteMetadata) {
		// The read loop treats this owner-written timing as immutable once
		// bytes can reach the provider. Prepare it before acknowledging the
		// writer; dispatch accounting stays unpublished until authorization.
		if pending != nil && pending.Timing != nil {
			pending.Timing.DispatchedAt = prepared.DequeuedAt
		}
	})
	if !metadata.Committed {
		// No provider can have received this frame. Clear provisional timing
		// before the owner publishes its failure outcome or exhausts retries.
		if pending != nil && pending.Timing != nil {
			pending.Timing.DispatchedAt = time.Time{}
		}
	} else if onCommitted != nil {
		onCommitted(metadata)
	}
	return metadata, err
}
