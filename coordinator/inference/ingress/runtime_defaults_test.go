package ingress

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestModelRuntimeDefaults(t *testing.T) {
	desired := map[string]any{
		"reasoning_parser":       "qwen3",
		"tool_call_parser":       "qwen3_coder",
		"chat_template_required": true,
	}

	t.Run("fills allowlisted parser defaults only", func(t *testing.T) {
		parsed := map[string]any{"model": registry.Qwen38NAXModelID}
		defaults := newModelRuntimeDefaults(parsed)
		if !defaults.apply(parsed, desired) {
			t.Fatal("expected request defaults to change the body")
		}
		if parsed["reasoning_parser"] != "qwen3" || parsed["tool_call_parser"] != "qwen3_coder" {
			t.Fatalf("parser defaults = %#v", parsed)
		}
		if _, leaked := parsed["chat_template_required"]; leaked {
			t.Fatal("provider/catalog-only runtime parameter leaked into request body")
		}
	})

	t.Run("recomputes same different absent and retry defaults", func(t *testing.T) {
		parsed := map[string]any{"model": "alias"}
		defaults := newModelRuntimeDefaults(parsed)
		if !defaults.apply(parsed, desired) {
			t.Fatal("desired defaults were not injected")
		}

		same := map[string]any{
			"reasoning_parser": "qwen3",
			"tool_call_parser": "qwen3_coder",
		}
		if defaults.apply(parsed, same) {
			t.Fatalf("same defaults unexpectedly changed request: %#v", parsed)
		}

		different := map[string]any{
			"reasoning_parser": "deepseek_r1",
			"tool_call_parser": "hermes",
			"server_only":      "must-not-leak",
		}
		if !defaults.apply(parsed, different) {
			t.Fatal("different fallback defaults were not applied")
		}
		if parsed["reasoning_parser"] != "deepseek_r1" || parsed["tool_call_parser"] != "hermes" {
			t.Fatalf("fallback defaults = %#v", parsed)
		}
		if _, leaked := parsed["server_only"]; leaked {
			t.Fatal("arbitrary runtime parameter leaked into request body")
		}

		if !defaults.apply(parsed, nil) {
			t.Fatal("absent fallback defaults did not remove injected values")
		}
		if _, exists := parsed["reasoning_parser"]; exists {
			t.Fatalf("reasoning_parser survived absent defaults: %#v", parsed)
		}
		if _, exists := parsed["tool_call_parser"]; exists {
			t.Fatalf("tool_call_parser survived absent defaults: %#v", parsed)
		}

		if !defaults.apply(parsed, desired) {
			t.Fatal("retrying desired build did not recompute defaults")
		}
		if parsed["reasoning_parser"] != "qwen3" || parsed["tool_call_parser"] != "qwen3_coder" {
			t.Fatalf("retried desired defaults = %#v", parsed)
		}
	})

	t.Run("explicit consumer values win across concrete models", func(t *testing.T) {
		parsed := map[string]any{
			"reasoning_parser": "deepseek_r1",
			"tool_call_parser": "qwen_xml",
		}
		defaults := newModelRuntimeDefaults(parsed)
		for _, runtimeParameters := range []map[string]any{
			desired,
			{"reasoning_parser": "other_reasoning", "tool_call_parser": "other_tools"},
			nil,
		} {
			if defaults.apply(parsed, runtimeParameters) {
				t.Fatalf("explicit request values changed for %#v", runtimeParameters)
			}
		}
		if parsed["reasoning_parser"] != "deepseek_r1" || parsed["tool_call_parser"] != "qwen_xml" {
			t.Fatalf("explicit values changed: %#v", parsed)
		}
	})

	t.Run("malformed metadata is ignored", func(t *testing.T) {
		parsed := map[string]any{}
		defaults := newModelRuntimeDefaults(parsed)
		if defaults.apply(parsed, map[string]any{
			"reasoning_parser": 7,
			"tool_call_parser": "  ",
		}) {
			t.Fatalf("malformed metadata changed request: %#v", parsed)
		}
	})
}
