package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const defaultMinInputTokens = 32
const minInputTokensParameter = "min_input_tokens"

func readDefaultMinInputTokens() int {
	n := env.EnvInt(env.EnvPrefix+"_MIN_INPUT_TOKENS", defaultMinInputTokens)
	if n < 0 || n > math.MaxInt32 {
		return defaultMinInputTokens
	}
	return n
}

// inputTokenFloorValue accepts JSON integers, including integral float64s
// produced by the registry decoder, without truncating fractions or overflow.
func inputTokenFloorValue(value any) (int, bool) {
	var n float64
	switch v := value.(type) {
	case int:
		return v, v >= 0 && v <= math.MaxInt32
	case float64:
		n = v
	case json.Number:
		var err error
		n, err = v.Float64()
		if err != nil {
			return 0, false
		}
	default:
		return 0, false
	}
	if math.IsNaN(n) || math.IsInf(n, 0) || n < 0 || n > math.MaxInt32 || n != math.Trunc(n) {
		return 0, false
	}
	return int(n), true
}

func validateInputTokenFloor(parameters map[string]any) error {
	value := parameters[minInputTokensParameter]
	if value == nil { // omitted or null inherits the deployment default
		return nil
	}
	if _, ok := inputTokenFloorValue(value); !ok {
		return fmt.Errorf("runtime_parameters.min_input_tokens must be an integer between 0 and %d, or null to inherit the default", math.MaxInt32)
	}
	return nil
}

func minimumInputTokens(fallback int, parameters map[string]any) int {
	if n, ok := inputTokenFloorValue(parameters[minInputTokensParameter]); ok {
		return n // explicit zero disables the floor for this model
	}
	return fallback
}

// rejectShortInput applies a catalog-owned minimum to the existing media-aware
// routing estimate, not the provider's eventual tokenizer count. Consumer body
// fields cannot override it. Call before charging/routing, and again whenever an
// alias changes builds (the caller refunds any reservation on that path).
func (s *Server) rejectShortInput(w http.ResponseWriter, r *http.Request, parsed map[string]any, publicModel, model string, estimatedTokens int, parameters map[string]any) bool {
	minimum := minimumInputTokens(s.defaultMinInputTokens, parameters)
	if estimatedTokens >= minimum {
		return false
	}
	stream, _ := parsed["stream"].(bool)
	s.recordRejection(rejectionInfo{
		r:                     r,
		stage:                 "validation",
		reasonCode:            "input_too_short",
		httpStatus:            http.StatusBadRequest,
		keyID:                 keyIDFromContext(r.Context()),
		consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
		requestedModel:        publicModel,
		resolvedModel:         model,
		stream:                stream,
		estimatedPromptTokens: estimatedTokens,
		requestedMaxTokens:    estimateRequestedMaxTokens(parsed),
		params:                rejectionSamplingParams(parsed),
		requiresVision:        detectMediaRequirement(parsed),
		hasTools:              requestHasTools(parsed),
	})
	writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
		fmt.Sprintf("input is too short for model %q: estimated %d input tokens; minimum is %d", publicModel, estimatedTokens, minimum),
		withCode("input_too_short")))
	return true
}

// checkInitialInputFloor defers aliases when only one build passes the floor,
// until ordinary capacity and TTFT admission chooses the final build. Both quota
// and balance admission wait for validation. A lower floor alone never causes fallback.
func (s *Server) checkInitialInputFloor(w http.ResponseWriter, r *http.Request, parsed map[string]any, publicModel, model string, tokens int, parameters map[string]any) (deferred, handled bool) {
	currentAllows := tokens >= minimumInputTokens(s.defaultMinInputTokens, parameters)
	target, alias := s.registry.AliasTarget(publicModel)
	if alias && target.Desired == model && target.Previous != "" {
		rec, err := s.store.GetModelRegistryRecord(target.Previous)
		if s.inputFloorRegistryReadFailed(w, target.Previous, err) {
			return false, true
		}
		var previousParameters map[string]any
		if rec != nil {
			previousParameters = rec.RuntimeParameters
		}
		previousAllows := tokens >= minimumInputTokens(s.defaultMinInputTokens, previousParameters)
		if currentAllows && previousAllows {
			return false, false
		}
		if currentAllows || previousAllows {
			return true, false // only one build can pass; validate selection before charging
		}
	}
	if currentAllows {
		return false, false
	}
	return false, s.rejectShortInput(w, r, parsed, publicModel, model, tokens, parameters)
}

// A genuinely absent record (e.g. a local/self-route model) has no override.
// A failed lookup is not evidence that the override is absent.
func (s *Server) inputFloorRegistryReadFailed(w http.ResponseWriter, model string, err error) bool {
	if err == nil || errors.Is(err, store.ErrNotFound) {
		return false
	}
	s.logger.Error("cannot resolve model input token floor", "model", model, "error", err)
	s.writeServiceUnavailable(w, model)
	return true
}
