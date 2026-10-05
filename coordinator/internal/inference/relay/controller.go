// Package relay delivers provider output to consumers. The request owner keeps
// reservation and settlement authority through the supplied lifecycle operations.
package relay

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const inferenceTimeout = 600 * time.Second
const phaseAfterCommit = "after_commit"

type Controller struct {
	Observation   *observation.Owner
	Refund        func(*registry.PendingRequest, string) bool
	Success       func(*registry.PendingRequest)
	Error         func(string, *registry.PendingRequest, int, string, string, string, ...protocol.CoordinatorInferenceErrorCause)
	Outcome       func(*registry.PendingRequest, *store.InferenceRouteOutcome)
	ProviderError func(http.ResponseWriter, protocol.InferenceErrorMessage)
}
