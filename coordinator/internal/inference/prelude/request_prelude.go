package prelude

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// Result carries the parsed request shape produced by the shared
// prelude: the forward body (decoded map + lazily serialized bytes), the
// untouched input bytes, and the consumer-requested model name (alias or raw
// build id, pre-resolution). originalTools is the caller's pre-normalization
// tools value when the prelude repaired a tool schema (nil otherwise); the
// tool-constraint validator must judge that view, never the repaired copy.
type Result struct {
	Body            inreq.ForwardBody
	OriginalRawBody []byte
	Parsed          map[string]any
	Model           string
	OriginalTools   []any
}

// Parser applies the shared shape validation and per-key model policy before
// either consumer endpoint enters admission or contacts a provider.
type Parser struct {
	KeyModelAllowed func(context.Context, string) bool
}

func (s *Parser) Parse(w http.ResponseWriter, r *http.Request) (Result, bool) {
	receivedAt := time.Now()
	// Retain the caller's body while decoding routing and request-owned fields.
	// Provider serialization is deferred until endpoint/model rewrites finish.
	// Cap it first: io.ReadAll would otherwise buffer an unbounded body and a
	// multi-GB POST would OOM the coordinator.
	r.Body = http.MaxBytesReader(w, r.Body, inreq.MaxInferenceBodyBytes)
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			httpx.WriteJSON(w, http.StatusRequestEntityTooLarge, httpx.ErrorResponse("invalid_request_error",
				fmt.Sprintf("request body exceeds the %d-byte limit", inreq.MaxInferenceBodyBytes)))
			return Result{}, false
		}
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "failed to read request body"))
		return Result{}, false
	}

	parsed, ok := parseJSONBody(w, rawBody)
	if !ok {
		return Result{}, false
	}
	// The handlers use false for an absent/non-boolean stream field. Capture
	// that parsed mode before model lookup or any subsequent validation exits.
	stream, _ := parsed["stream"].(bool)
	observation.MarkRequestStream(r, stream)

	// Normalize tool JSON-Schemas before dispatch so no provider sees the
	// schema shapes that crash Gemma-style chat templates ("upper filter
	// requires string" — nullable array types, missing types). The Swift
	// provider repairs only tools[].function.parameters, after media inlining
	// may have pushed the body past its size gate, so flat and input_schema
	// tools and large bodies depend on this pass (see toolschema.go). The
	// repair runs on the decoded map (one parse per request); the caller's
	// original tools are kept for constraint validation.
	originalTools, _ := inreq.NormalizeParsedToolSchemas(parsed, rawBody)
	if stop, ok := parsed["stop"].(string); ok {
		parsed["stop"] = []any{stop}
	}

	model, _ := parsed["model"].(string)
	if model == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "model is required", httpx.WithParam("model")))
		return Result{}, false
	}

	// Per-key model allow-list enforcement (phase 3). Checked on the
	// consumer-requested name (alias or raw id) before alias resolution.
	if !s.KeyModelAllowed(r.Context(), model) {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("model_not_allowed",
			fmt.Sprintf("this API key is not permitted to use model %q", model), httpx.WithParam("model")))
		return Result{}, false
	}
	// Reject an invalid caller budget before runtime defaults, alias lowering or
	// reservation accounting can replace it with an executable positive bound.
	if field := inreq.InvalidOutputTokenField(parsed); field != "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			field+" must be a non-negative integer", httpx.WithParam(field)))
		return Result{}, false
	}

	// Own the template date before any model fallback or endpoint lowering.
	// Always overwrite the reserved field; originalRawBody remains untouched.
	promptcontract.SetRequestDate(parsed, receivedAt)

	return Result{
		Body:            inreq.ForwardBody{Parsed: parsed, Bytes: rawBody, Dirty: true},
		OriginalRawBody: rawBody,
		Parsed:          parsed,
		Model:           model,
		OriginalTools:   originalTools,
	}, true
}

// parseJSONBody unmarshals the request body, writing the standard invalid-JSON
// error and returning ok=false on failure. Split out so both the prelude and any
// re-parse site share one error shape.
func parseJSONBody(w http.ResponseWriter, rawBody []byte) (map[string]any, bool) {
	parsed, err := inreq.DecodeInferenceJSONObject(rawBody)
	if err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return nil, false
	}
	return parsed, true
}
