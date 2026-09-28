package api

import (
	"fmt"
	"net/http"
)

// Inspect typed message/output positions only, never tool arguments or strings.
func requestHasMediaToolResults(parsed map[string]any) bool {
	for _, field := range []string{"messages", "input"} {
		items, _ := parsed[field].([]any)
		for _, value := range items {
			item, ok := value.(map[string]any)
			if !ok {
				continue
			}
			var content any
			if field == "input" && item["type"] == "function_call_output" {
				content = item["output"]
			} else if item["role"] == "tool" || item["role"] == "function" {
				content = item["content"]
			}
			if _, media := contentShape(content); media > 0 {
				return true
			}
		}
	}
	return false
}

func (s *Server) nativeMediaToolsFailFast(w http.ResponseWriter, model, publicModel string, policy selfRoutePolicy, serials []string) bool {
	if s.registry.HasNativeMediaToolProviderForRouting(model, policy.ownerAccountID, policy.enabled, policy.prefer, serials...) {
		return false
	}
	if !policy.enabled && !policy.prefer && s.registry.HasProviderForModel(model, serials...) &&
		!s.registry.HasProviderAdvertisingNativeMediaTools(model, serials...) {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"native media tools are not supported for multimodal requests on this model", withParam("model")))
		return true
	}
	writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
		fmt.Sprintf("no eligible provider for model %q supports native media tools", publicModel), withParam("model")))
	return true
}
