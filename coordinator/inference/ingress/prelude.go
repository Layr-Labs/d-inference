package ingress

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/accounts"
	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// inferencePrelude carries the parsed request shape produced by the shared
// prelude: the forward body (decoded map + lazily serialized bytes), the
// untouched input bytes, and the consumer-requested model name (alias or raw
// build id, pre-resolution). originalTools is the caller's pre-normalization
// tools value when the prelude repaired a tool schema (nil otherwise); the
// tool-constraint validator must judge that view, never the repaired copy.
type inferencePrelude struct {
	body            forwardBody
	originalRawBody []byte
	parsed          map[string]any
	model           string
	originalTools   []any
}

// parseInferencePrelude runs the request prelude shared verbatim by
// handleChatCompletions and handleGenericInference: read the body, parse JSON
// (once), normalize tool JSON-Schemas on the decoded map (so pre-0.6.3
// providers never see chat-template-crashing shapes), require a model, and
// enforce the per-key model allowlist. On any failure it writes the exact
// OpenAI-compatible error response and returns ok=false; the caller must then
// return immediately.
func (s *Controller) parseInferencePrelude(w http.ResponseWriter, r *http.Request) (inferencePrelude, bool) {
	receivedAt := time.Now()
	// Retain the caller's body while decoding routing and request-owned fields.
	// Provider serialization is deferred until endpoint/model rewrites finish.
	// Cap it first: io.ReadAll would otherwise buffer an unbounded body and a
	// multi-GB POST would OOM the coordinator.
	r.Body = http.MaxBytesReader(w, r.Body, maxInferenceBodyBytes)
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			httpresponse.WriteJSON(w, http.StatusRequestEntityTooLarge, httpresponse.ErrorBody("invalid_request_error",
				fmt.Sprintf("request body exceeds the %d-byte limit", maxInferenceBodyBytes)))
			return inferencePrelude{}, false
		}
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "failed to read request body"))
		return inferencePrelude{}, false
	}

	parsed, ok := parseJSONBody(w, rawBody)
	if !ok {
		return inferencePrelude{}, false
	}
	// The handlers use false for an absent/non-boolean stream field. Capture
	// that parsed mode before model lookup or any subsequent validation exits.
	{
		stream, _ := parsed["stream"].(bool)
		s.deps.Observer.ParsedStream(r.Context(), stream)
	}

	// Normalize tool JSON-Schemas before dispatch so providers running binaries
	// older than 0.6.3 (which normalize provider-side, #310) never see the
	// schema shapes that crash Gemma-style chat templates ("upper filter
	// requires string" — nullable array types, missing types). Centralizing
	// this in the coordinator covers the whole fleet the moment the
	// coordinator deploys, instead of waiting out provider update lag. The
	// repair runs on the decoded map (one parse per request); the caller's
	// original tools are kept for constraint validation.
	originalTools, _ := toolpolicy.NormalizeParsed(parsed, rawBody)
	if stop, ok := parsed["stop"].(string); ok {
		parsed["stop"] = []any{stop}
	}

	model, _ := parsed["model"].(string)
	if model == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "model is required", httpresponse.WithParam("model")))
		return inferencePrelude{}, false
	}

	// Per-key model allow-list enforcement (phase 3). Checked on the
	// consumer-requested name (alias or raw id) before alias resolution.
	if !accounts.KeyModelAllowed(r.Context(), model) {
		httpresponse.WriteJSON(w, http.StatusForbidden, httpresponse.ErrorBody("model_not_allowed",
			fmt.Sprintf("this API key is not permitted to use model %q", model), httpresponse.WithParam("model")))
		return inferencePrelude{}, false
	}

	// Own the template date before any model fallback or endpoint lowering.
	// Always overwrite the reserved field; originalRawBody remains untouched.
	promptcontract.SetRequestDate(parsed, receivedAt)

	return inferencePrelude{
		body:            forwardBody{parsed: parsed, bytes: rawBody, dirty: true},
		originalRawBody: rawBody,
		parsed:          parsed,
		model:           model,
		originalTools:   originalTools,
	}, true
}
