// Package response encodes inference responses and owns per-stream formatting
// state. Callers retain channel consumption, completion arbitration, and billing.
package response

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// consumerModel returns the model name to echo back to the consumer: the public
// alias they requested when set, otherwise the concrete build id (raw-id
// requests and any internal caller that didn't populate PublicModel).
func ConsumerModel(pr *registry.PendingRequest) string {
	if pr.PublicModel != "" {
		return pr.PublicModel
	}
	return pr.Model
}
