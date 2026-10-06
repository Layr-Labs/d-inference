package inference

import (
	"fmt"
	"net/http"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
)

func (s *Owner) nativeMediaToolsFailFast(w http.ResponseWriter, model, publicModel string, policy selfRoutePolicy, serials []string) bool {
	if s.registry.HasNativeMediaToolProviderForRouting(model, policy.ownerAccountID, policy.enabled, policy.prefer, serials...) {
		return false
	}
	if !policy.enabled && !policy.prefer && s.registry.HasProviderForModel(model, serials...) &&
		!s.registry.HasProviderAdvertisingNativeMediaTools(model, serials...) {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"native media tools are not supported for multimodal requests on this model", httpx.WithParam("model")))
		return true
	}
	httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
		fmt.Sprintf("no eligible provider for model %q supports native media tools", publicModel), httpx.WithParam("model")))
	return true
}
