package api

import (
	"encoding/json"
	"math"
	"reflect"
	"testing"
)

func TestOutputTokenBudgetValidationPreservesSupportedBounds(t *testing.T) {
	for _, value := range []any{nil, 0, 1, int32(2), int64(8192), float64(16384), json.Number("-0"), json.Number("0"), json.Number("262144")} {
		for _, field := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
			parsed := map[string]any{field: value, "tools": []any{map[string]any{"max_tokens": -1}}, "metadata": map[string]any{"max_output_tokens": -3}}
			before, err := json.Marshal(parsed)
			if err != nil {
				t.Fatal(err)
			}
			if bad := invalidOutputTokenField(parsed); bad != "" {
				t.Errorf("valid %s=%v rejected: %s", field, value, bad)
			}
			after, err := json.Marshal(parsed)
			if err != nil || !reflect.DeepEqual(before, after) {
				t.Fatal("budget validation mutated input")
			}
		}
	}
	if field := invalidOutputTokenField(map[string]any{}); field != "" {
		t.Fatal("absent budget rejected")
	}
	for _, value := range []any{nil, 0, json.Number("0")} {
		parsed := map[string]any{"max_tokens": value}
		if !ensureMaxTokensBound(parsed, false, 8192) || parsed["max_tokens"] != 8192 {
			t.Fatal("legacy null/zero default changed")
		}
	}
	parsed := map[string]any{"max_completion_tokens": json.Number("64")}
	if !ensureMaxTokensBound(parsed, false, 8192) || parsed["max_tokens"] != 64 {
		t.Fatal("positive alias mapping changed")
	}
}

func TestOutputTokenBudgetValidationRejectsAllInvalidAliases(t *testing.T) {
	for _, value := range []any{-1, int32(-2), int64(-3), float64(-0.5), float64(1.5), math.Inf(1), math.NaN(), "-1", true, []any{1}, map[string]any{}, json.Number("-1"), json.Number("1.5"), json.Number("-1e-9999"), json.Number("1e9999"), json.Number("9223372036854775808")} {
		for _, field := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
			parsed := map[string]any{"max_tokens": 64, "max_completion_tokens": 64, "max_output_tokens": 64}
			parsed[field] = value
			if bad := invalidOutputTokenField(parsed); bad != field {
				t.Errorf("invalid %s=%v masked by another alias: got %q", field, value, bad)
			}
		}
	}
}
