package api

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func resolvedModelToolParserFamily(
	modelID, modelType string,
	runtimeParameters map[string]any,
) toolpolicy.ParserFamily {
	if parser, ok := runtimeParameters["tool_call_parser"].(string); ok {
		if family := toolpolicy.ParserFamilyFor(parser); family != "" {
			return family
		}
	}
	normalizedType := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(modelType)), "-", "_")
	switch {
	case modelID == registry.Qwen38NAXModelID,
		strings.HasPrefix(normalizedType, "qwen3_5"):
		return toolpolicy.Qwen
	case strings.HasPrefix(normalizedType, "gemma4"),
		strings.HasPrefix(normalizedType, "gemma_4"):
		return toolpolicy.Gemma
	default:
		return ""
	}
}

func validateResolvedToolConstraintParser(
	root map[string]any,
	mode toolpolicy.Mode,
	modelID, modelType string,
	runtimeParameters map[string]any,
) error {
	if !mode.RequiresInferenceConstraint() {
		return nil
	}
	raw, exists := root["tool_call_parser"]
	if !exists || raw == nil {
		return nil // provider infers its parser from the resolved model type
	}
	parser, ok := raw.(string)
	if !ok {
		return &toolpolicy.ValidationError{
			Kind: toolpolicy.InvalidRequest, Message: "tool_call_parser must be a string", Param: "tool_call_parser",
		}
	}
	actual := toolpolicy.ParserFamilyFor(parser)
	if actual == "" {
		return &toolpolicy.ValidationError{
			Kind:    toolpolicy.InvalidRequest,
			Message: "inference-enforced tool_choice requires a supported Gemma or Qwen tool_call_parser",
			Param:   "tool_call_parser",
		}
	}
	expected := resolvedModelToolParserFamily(modelID, modelType, runtimeParameters)
	if expected != "" && actual != expected {
		return &toolpolicy.ValidationError{
			Kind: toolpolicy.InvalidRequest,
			Message: fmt.Sprintf(
				"tool_call_parser %q is incompatible with resolved model %q",
				parser, modelID),
			Param: "tool_call_parser",
		}
	}
	return nil
}

func (s *Server) recordToolConstraintMetric(mode toolpolicy.Mode, outcome string) {
	if mode == "" {
		mode = "invalid"
	}
	s.ddIncr("inference.tool_constraint", []string{
		"mode:" + string(mode),
		"outcome:" + outcome,
	})
}

func writeToolConstraintValidationError(
	w http.ResponseWriter,
	err error,
) {
	if typed, ok := err.(*toolpolicy.ValidationError); ok {
		options := []errorDetailOpt{}
		if typed.Param != "" {
			options = append(options, withParam(typed.Param))
		}
		status := http.StatusBadRequest
		if typed.Kind == toolpolicy.UnsupportedSchema {
			status = http.StatusUnprocessableEntity
		}
		writeJSON(w, status, errorResponse(
			"invalid_request_error", typed.Message, options...))
		return
	}
	writeJSON(w, http.StatusBadRequest, errorResponse(
		"invalid_request_error", err.Error()))
}
