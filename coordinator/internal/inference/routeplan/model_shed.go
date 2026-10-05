package routeplan

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backoff"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type ModelShedDependencies struct {
	Registry    *registry.Registry
	Observation *observation.Owner
	Backoff     *backoff.Policy
	Rejected    func(string, string) bool
	Sampling    func(map[string]any) json.RawMessage
	Record      func(*http.Request, store.RejectionRecord)
}

type ModelShedder struct{ deps ModelShedDependencies }

func NewModelShedder(deps ModelShedDependencies) *ModelShedder { return &ModelShedder{deps: deps} }

// Shed precedes reservation/routing; owner-only requests cannot fall back to
// the public fleet and therefore bypass the operator's public model shed.
func (s *ModelShedder) Shed(w http.ResponseWriter, r *http.Request, parsed map[string]any, scope dispatch.Scope, publicModel, model string, stream bool, prompt, maxTokens int, vision, tools bool) bool {
	if scope.SelfRouteOnly || !s.deps.Rejected(model, publicModel) {
		return false
	}
	retryAfter := s.deps.Backoff.Estimate(model)
	if retryAfter <= 0 {
		retryAfter = 30
	}
	s.deps.Observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry.ModelType(model), "outcome:model_shed"})
	s.deps.Record(r, store.RejectionRecord{
		Stage: "model_shed", ReasonCode: "model_shed", HTTPStatus: http.StatusTooManyRequests,
		KeyID: access.KeyIDFromContext(r.Context()), ConsumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
		RequestedModel: publicModel, ResolvedModel: model, Stream: stream,
		EstimatedPromptTokens: prompt, RequestedMaxTokens: maxTokens, RequiresVision: vision, HasTools: tools,
		SelfRouteOnly: scope.SelfRouteOnly, PreferOwner: scope.PreferOwner,
		RetryAfterMs: retryAfter * 1000, Params: s.deps.Sampling(parsed),
	})
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	httpx.WriteJSON(w, http.StatusTooManyRequests, httpx.ErrorResponse("rate_limit_exceeded",
		fmt.Sprintf("model %q is temporarily rate-limited \u2014 retry after %ds", publicModel, retryAfter), httpx.WithCode("rate_limit_exceeded")))
	return true
}
