package request_test

import (
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestValidateResolvedToolConstraintParserBindsModelFamily(t *testing.T) {
	tests := []struct {
		name              string
		parser            string
		modelID           string
		modelType         string
		runtimeParameters map[string]any
		wantError         bool
	}{
		{
			name:   "Qwen parser on Qwen",
			parser: "qwen3_coder", modelID: registry.Qwen38NAXModelID,
		},
		{
			name:   "Gemma parser on Qwen",
			parser: "gemma", modelID: registry.Qwen38NAXModelID, wantError: true,
		},
		{
			name:   "Gemma parser on Gemma",
			parser: "gemma4", modelType: "gemma4",
		},
		{
			name:   "Qwen parser on Gemma",
			parser: "qwen_xml", modelType: "gemma4_text", wantError: true,
		},
		{
			name:   "runtime default defines family",
			parser: "qwen3_coder", modelID: "opaque-build",
			runtimeParameters: map[string]any{"tool_call_parser": "qwen3_coder"},
		},
		{
			name:   "runtime default rejects other family",
			parser: "gemma", modelID: "opaque-build",
			runtimeParameters: map[string]any{"tool_call_parser": "qwen3_coder"},
			wantError:         true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := inreq.ValidateResolvedToolConstraintParser(
				map[string]any{"tool_call_parser": test.parser},
				inreq.ToolChoiceRequired,
				test.modelID,
				test.modelType,
				test.runtimeParameters,
			)
			if test.wantError && err == nil {
				t.Fatal("mismatched parser unexpectedly accepted")
			}
			if !test.wantError && err != nil {
				t.Fatalf("matching parser rejected: %v", err)
			}
		})
	}
}
