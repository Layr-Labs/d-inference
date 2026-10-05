package rejection

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// DispatchMetadata contains the admitted request's non-content ledger fields.
type DispatchMetadata struct {
	Model                 string
	PublicModel           string
	ConsumerKey           string
	Stream                bool
	EstimatedPromptTokens int
	RequestedMaxTokens    int
	RequiresVision        bool
	HasTools              bool
	SelfRouteOnly         bool
	PreferOwner           bool
	OverflowBodyBytes     int
}

type Prepared struct {
	Record      *store.RejectionRecord
	Servability Servability
}

// BuildDispatch constructs the record consumed by the rejection writer. A
// known payload overflow or scheduler decision must not trigger another scan.
func BuildDispatch(r *http.Request, in DispatchMetadata, stage, reason string, status, retryAfterMS int, decision *registry.RoutingDecision) Prepared {
	prepared := Prepared{Record: &store.RejectionRecord{
		Stage: stage, ReasonCode: reason, HTTPStatus: status,
		KeyID: access.KeyIDFromContext(r.Context()), ConsumerKeyHash: store.HashKey(in.ConsumerKey),
		RequestedModel: in.PublicModel, ResolvedModel: in.Model, Stream: in.Stream,
		EstimatedPromptTokens: in.EstimatedPromptTokens, RequestedMaxTokens: in.RequestedMaxTokens,
		RequiresVision: in.RequiresVision, HasTools: in.HasTools,
		SelfRouteOnly: in.SelfRouteOnly, PreferOwner: in.PreferOwner, RetryAfterMs: retryAfterMS,
	}}
	if reason == "payload_too_large" {
		prepared.Servability.Computed = true
		if in.OverflowBodyBytes > 0 {
			prepared.Record.RequestBodyBytes = in.OverflowBodyBytes
		}
	}
	if decision != nil {
		prepared.Servability.Computed = true
		prepared.Record.CandidateCount = decision.CandidateCount
		prepared.Record.CapacityRejections = decision.CapacityRejections
		prepared.Record.ModelTooLargeRejections = decision.ModelTooLargeRejections
		prepared.Record.VisionRejections = decision.VisionRejections
		prepared.Record.BestTTFTMs = decision.BestTTFTMs
	}
	return prepared
}
