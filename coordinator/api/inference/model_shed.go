package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) NewModelShedder() *routeplan.ModelShedder {
	return routeplan.NewModelShedder(routeplan.ModelShedDependencies{
		Registry: s.registry, Observation: s.observation, Backoff: s.backoff,
		Rejected: s.modelShed, Sampling: rejectionSamplingParams,
		Record: func(r *http.Request, rec store.RejectionRecord) {
			s.recordRejection(rejectionInfo{
				r: r, stage: rec.Stage, reasonCode: rec.ReasonCode, httpStatus: rec.HTTPStatus,
				keyID: rec.KeyID, consumerKeyHash: rec.ConsumerKeyHash,
				requestedModel: rec.RequestedModel, resolvedModel: rec.ResolvedModel, stream: rec.Stream,
				estimatedPromptTokens: rec.EstimatedPromptTokens, requestedMaxTokens: rec.RequestedMaxTokens,
				requiresVision: rec.RequiresVision, hasTools: rec.HasTools,
				selfRouteOnly: rec.SelfRouteOnly, preferOwner: rec.PreferOwner,
				retryAfterMs: rec.RetryAfterMs, params: rec.Params,
			})
		},
	})
}
