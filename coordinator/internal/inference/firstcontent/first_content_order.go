package firstcontent

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func EmptyCompletionPrecedesChunk(
	empty *registry.PendingRequest,
	chunk registry.ProviderChunk,
) bool {
	completedAt, ok := empty.OnTimeEmptyCompletionIngress()
	return ok &&
		!chunk.ReceivedAt.IsZero() &&
		!completedAt.After(chunk.ReceivedAt)
}
