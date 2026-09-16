package ingress

import (
	"net/http"
)

// handleCompletions handles POST /v1/completions.
// Proxies OpenAI-compatible text completions to the selected provider over the
// E2E-encrypted WebSocket relay (MLX-Swift in-process backend).
func (s *Controller) Completions(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/completions")
}

// handleAnthropicMessages handles POST /v1/messages.
// Proxies the Anthropic-compatible messages API to the selected provider over
// the E2E-encrypted WebSocket relay (MLX-Swift in-process backend).
func (s *Controller) Messages(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/messages")
}
