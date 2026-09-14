package toolpolicy

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestConstrainedGrammarCostChargesNullBranchOnlyWhenEnumAdmitsNull(t *testing.T) {
	nullableEnum := func(enum []any) map[string]any {
		return map[string]any{
			"type": []any{"string", "null"},
			"enum": enum,
		}
	}
	plain := constrainedSchemaGrammarCost(map[string]any{
		"type": "string",
		"enum": []any{"ok"},
	})
	withoutNull := constrainedSchemaGrammarCost(nullableEnum([]any{"ok"}))
	if withoutNull != plain {
		t.Fatalf("enum without null charged a null branch: %d != %d", withoutNull, plain)
	}
	withNull := constrainedSchemaGrammarCost(nullableEnum([]any{"ok", nil}))
	if want := plain + constrainedNullableBranchCost; withNull != want {
		t.Fatalf("enum with null lost its null branch: %d != %d", withNull, want)
	}
}

func TestValidateToolConstraintRequestRejectsProviderGrammarExplosion(t *testing.T) {
	var value any = map[string]any{"type": "string"}
	for range 4 {
		value = map[string]any{
			"type":     "array",
			"items":    value,
			"maxItems": 16,
		}
	}
	body, err := json.Marshal(map[string]any{
		"model":    "m",
		"messages": []any{map[string]any{"role": "user", "content": "x"}},
		"tools": []any{map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": "expand",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"value": value,
					},
				},
			},
		}},
		"tool_choice": "required",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, validationErr := validateToolConstraintRequest(body)
	var typed *ValidationError
	if !errors.As(validationErr, &typed) {
		t.Fatalf("expected typed complexity rejection, got %T: %v", validationErr, validationErr)
	}
	if typed.Kind != UnsupportedSchema ||
		!strings.Contains(typed.Message, "grammar exceeds") {
		t.Fatalf("unexpected complexity rejection: %+v", typed)
	}
}

func TestValidateToolConstraintRequestRejectsNullArrayBounds(t *testing.T) {
	for _, bound := range []string{"minItems", "maxItems"} {
		t.Run(bound, func(t *testing.T) {
			body := []byte(fmt.Sprintf(`{
				"model":"m",
				"messages":[{"role":"user","content":"x"}],
				"tools":[{"type":"function","function":{
					"name":"expand",
					"parameters":{
						"type":"object",
						"properties":{
							"values":{"type":"array","items":{"type":"string"},"%s":null}
						}
					}
				}}],
				"tool_choice":"required"
			}`, bound))
			_, err := validateToolConstraintRequest(body)
			var typed *ValidationError
			if !errors.As(err, &typed) || typed.Kind != InvalidRequest {
				t.Fatalf("null %s accepted: %T %v", bound, err, err)
			}
		})
	}
}

func TestValidateToolConstraintRequestAcceptsIntegralDecimalArrayBounds(t *testing.T) {
	for _, bounds := range []string{
		`"minItems":1.0,"maxItems":2.0`,
		`"minItems":1e0,"maxItems":2e0`,
	} {
		body := []byte(fmt.Sprintf(`{
			"model":"m",
			"messages":[{"role":"user","content":"x"}],
			"tools":[{"type":"function","function":{
				"name":"expand",
				"parameters":{"type":"object","properties":{
					"values":{"type":"array","items":{"type":"string"},%s}
				}}
			}}],
			"tool_choice":"required"
		}`, bounds))
		if _, err := validateToolConstraintRequest(body); err != nil {
			t.Fatalf("integral decimal bounds %s rejected: %v", bounds, err)
		}
	}

	fractional := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{
			"name":"expand",
			"parameters":{"type":"object","properties":{
				"values":{"type":"array","items":{"type":"string"},"maxItems":1.5}
			}}
		}}],
		"tool_choice":"required"
	}`)
	if _, err := validateToolConstraintRequest(fractional); err == nil {
		t.Fatal("fractional array bound accepted")
	}
}

func TestValidateToolConstraintRequestAcceptsMathematicalIntegerFiniteValues(t *testing.T) {
	for _, literal := range []string{
		"1.0", "1e0", "-2.0", "-2e0", "9007199254740993.0",
	} {
		body := []byte(fmt.Sprintf(`{
			"model":"m",
			"messages":[{"role":"user","content":"x"}],
			"tools":[{"type":"function","function":{
				"name":"calculate",
				"parameters":{"type":"object","properties":{
					"value":{"type":"integer","const":%s}
				}}
			}}],
			"tool_choice":"required"
		}`, literal))
		if _, err := validateToolConstraintRequest(body); err != nil {
			t.Fatalf("mathematical integer %s rejected: %v", literal, err)
		}
	}
}

// The exact-integer parse must stay LINEAR in the literal length: json.Number
// carries raw request bytes unbounded, so a bignum-backed parse would hand an
// attacker free coordinator CPU per oversized literal.
func TestConstrainedExactNonnegativeIntBoundsAdversarialLiterals(t *testing.T) {
	longDigits := strings.Repeat("9", 4_000_000)
	cases := map[string]struct {
		literal string
		want    int
		wantErr bool
	}{
		"plain":                     {literal: "3", want: 3},
		"integral decimal":          {literal: "2.0", want: 2},
		"integral exponent":         {literal: "2e0", want: 2},
		"scaled exponent":           {literal: "1.6e1", want: 16},
		"zero with long fraction":   {literal: "0." + strings.Repeat("0", 100), want: 0},
		"fractional":                {literal: "1.5", wantErr: true},
		"negative":                  {literal: "-1", wantErr: true},
		"huge exponent":             {literal: "1e1000000", wantErr: true},
		"huge negative exponent":    {literal: "1e-1000000", wantErr: true},
		"multi-megabyte digits":     {literal: longDigits, wantErr: true},
		"multi-megabyte fractional": {literal: "1." + longDigits, wantErr: true},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			start := time.Now()
			got, err := constrainedExactNonnegativeInt(tc.literal)
			if elapsed := time.Since(start); elapsed > 250*time.Millisecond {
				t.Fatalf("parse took %v — superlinear parse regression", elapsed)
			}
			if tc.wantErr {
				if err == nil {
					t.Fatalf("literal accepted: %d", got)
				}
				return
			}
			if err != nil || got != tc.want {
				t.Fatalf("parse = %d, %v; want %d", got, err, tc.want)
			}
		})
	}
}

func TestValidateToolConstraintRequestChargesNullableBranches(t *testing.T) {
	properties := make(map[string]any, 128)
	for index := range 128 {
		properties[fmt.Sprintf("p%d", index)] = map[string]any{
			"type": []any{"string", "null"},
			"enum": []any{nil},
		}
	}
	tools := make([]any, 64)
	for index := range tools {
		tools[index] = map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": fmt.Sprintf("tool%d", index),
				"parameters": map[string]any{
					"type":       "object",
					"properties": properties,
				},
			},
		}
	}
	body, err := json.Marshal(map[string]any{
		"model":       "m",
		"messages":    []any{map[string]any{"role": "user", "content": "x"}},
		"tools":       tools,
		"tool_choice": "required",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, validationErr := validateToolConstraintRequest(body)
	var typed *ValidationError
	if !errors.As(validationErr, &typed) ||
		typed.Kind != UnsupportedSchema ||
		!strings.Contains(typed.Message, "grammar exceeds") {
		t.Fatalf("nullable grammar undercharged: %T %v", validationErr, validationErr)
	}
}
