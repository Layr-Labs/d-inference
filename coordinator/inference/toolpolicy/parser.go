package toolpolicy

import (
	"strings"
)

// ParserFamily identifies the tool parser dialect used for inference constraints.
type ParserFamily string

const (
	Gemma ParserFamily = "gemma"
	Qwen  ParserFamily = "qwen"
)

// ParserFamilyFor resolves supported parser aliases, returning empty for unknown
// dialects. It does not infer a parser from a model or registry record.
func ParserFamilyFor(parser string) ParserFamily {
	normalized := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(parser)), "-", "_")
	switch normalized {
	case "gemma", "gemma4", "gemma_4":
		return Gemma
	case "qwen3_coder", "qwen3_5", "qwen_xml", "xml", "xml_function":
		return Qwen
	default:
		return ""
	}
}

func supportsInferenceEnforcedToolChoice(parser string) bool {
	return ParserFamilyFor(parser) != ""
}
