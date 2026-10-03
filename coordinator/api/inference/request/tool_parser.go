package request

import (
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

type inferenceToolParserFamily string

const (
	inferenceToolParserGemma inferenceToolParserFamily = "gemma"
	inferenceToolParserQwen  inferenceToolParserFamily = "qwen"
)

func inferenceToolParserFamilyFor(parser string) inferenceToolParserFamily {
	normalized := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(parser)), "-", "_")
	switch normalized {
	case "gemma", "gemma4", "gemma_4":
		return inferenceToolParserGemma
	case "qwen3_coder", "qwen3_5", "qwen_xml", "xml", "xml_function":
		return inferenceToolParserQwen
	default:
		return ""
	}
}

func supportsInferenceEnforcedToolChoice(parser string) bool {
	return inferenceToolParserFamilyFor(parser) != ""
}

func resolvedModelToolParserFamily(
	modelID, modelType string,
	runtimeParameters map[string]any,
) inferenceToolParserFamily {
	if parser, ok := runtimeParameters["tool_call_parser"].(string); ok {
		if family := inferenceToolParserFamilyFor(parser); family != "" {
			return family
		}
	}
	normalizedType := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(modelType)), "-", "_")
	switch {
	case modelID == registry.Qwen38NAXModelID,
		strings.HasPrefix(normalizedType, "qwen3_5"):
		return inferenceToolParserQwen
	case strings.HasPrefix(normalizedType, "gemma4"),
		strings.HasPrefix(normalizedType, "gemma_4"):
		return inferenceToolParserGemma
	default:
		return ""
	}
}

func ValidateResolvedToolConstraintParser(
	root map[string]any,
	mode ToolChoiceMode,
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
		return invalidToolConstraint(
			"tool_call_parser must be a string", "tool_call_parser")
	}
	actual := inferenceToolParserFamilyFor(parser)
	if actual == "" {
		return invalidToolConstraint(
			"inference-enforced tool_choice requires a supported Gemma or Qwen tool_call_parser",
			"tool_call_parser")
	}
	expected := resolvedModelToolParserFamily(modelID, modelType, runtimeParameters)
	if expected != "" && actual != expected {
		return invalidToolConstraint(
			fmt.Sprintf(
				"tool_call_parser %q is incompatible with resolved model %q",
				parser, modelID),
			"tool_call_parser")
	}
	return nil
}
