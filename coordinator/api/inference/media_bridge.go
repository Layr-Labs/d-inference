package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	infermedia "github.com/eigeninference/d-inference/coordinator/internal/inference/media"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) mediaBridge() *infermedia.Bridge {
	return infermedia.NewBridge(infermedia.Dependencies{
		Resolver: s.mediaResolver, Logger: s.logger, Observation: s.observation,
		RecordRemote: s.recordRemoteMediaRejection, SelfRouteUnavailable: s.selfRouteUnavailable,
		Deadline: s.requestFirstContentDeadline, ServiceUnavailable: s.writeServiceUnavailable,
		RecordRejection: func(r *http.Request, parsed map[string]any, meta infermedia.ResolveMeta, status int) {
			s.recordRejection(rejectionInfo{
				r: r, stage: "validation", reasonCode: infermedia.RejectionReason(status), httpStatus: status,
				keyID: access.KeyIDFromContext(r.Context()), consumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
				requestedModel: meta.PublicModel, resolvedModel: meta.Model, stream: meta.Stream,
				estimatedPromptTokens: meta.EstimatedPromptTokens, requestedMaxTokens: meta.RequestedMaxTokens,
				requiresVision: true, hasTools: meta.HasTools, params: rejectionSamplingParams(parsed),
			})
		},
	})
}

func (s *Owner) gateRemoteMediaPreDispatch(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, requiresVision, hasTools bool) bool {
	if !requiresVision {
		return false
	}
	return s.mediaBridge().Gate(w, r, parsed, model, publicModel, requiresVision, hasTools, isSealedRequest(r))
}

func (s *Owner) resolveRemoteMedia(w http.ResponseWriter, r *http.Request, rawBody []byte, parsed map[string]any, timing *registry.RequestTiming, meta infermedia.ResolveMeta) ([]byte, bool, bool) {
	return s.mediaBridge().Resolve(w, r, rawBody, parsed, timing, meta)
}
