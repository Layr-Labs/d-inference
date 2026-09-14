package toolpolicy

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
)

var constrainedStringDelimiters = []string{
	`<|"|>`,
	"<escape>",
	"<|tool_call>",
	"<tool_call|>",
	"<start_function_call>",
	"<end_function_call>",
}

func constrainedSchemaFiniteValues(schema map[string]any) ([]any, bool) {
	if constant, ok := schema["const"]; ok {
		return []any{constant}, true
	}
	values, ok := schema["enum"].([]any)
	return values, ok
}

func constrainedValuesContainNull(values []any) bool {
	for _, value := range values {
		if value == nil {
			return true
		}
	}
	return false
}

func validateConstrainedFiniteValues(
	schema map[string]any,
	kind string,
	nullable bool,
	path string,
) error {
	constant, hasConstant := schema["const"]
	rawEnum, hasEnum := schema["enum"]
	if hasConstant && hasEnum {
		return invalidToolConstraint(path+" cannot contain both const and enum", "tools")
	}
	var values []any
	if hasConstant {
		values = []any{constant}
	} else if hasEnum {
		var ok bool
		values, ok = rawEnum.([]any)
		if !ok || len(values) == 0 || len(values) > 128 {
			return invalidToolConstraint(path+".enum must contain 1...128 values", "tools")
		}
	} else {
		return nil
	}
	if kind == "object" || kind == "array" || kind == "number" {
		return unsupportedToolConstraint(path + " uses enum/const on " + kind)
	}
	for _, value := range values {
		if value == nil && nullable {
			continue
		}
		if kind == "string" {
			if text, ok := value.(string); ok {
				for _, marker := range constrainedStringDelimiters {
					if strings.Contains(text, marker) {
						return unsupportedToolConstraint(
							path + " string enum/const contains a Gemma parser delimiter")
					}
				}
			}
		}
		if !constrainedValueMatchesType(value, kind) {
			return invalidToolConstraint(
				path+" enum/const does not match type "+kind, "tools")
		}
	}
	return nil
}

func constrainedValueMatchesType(value any, kind string) bool {
	switch kind {
	case "string":
		_, ok := value.(string)
		return ok
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "integer":
		number, ok := value.(json.Number)
		if !ok {
			return false
		}
		return constrainedJSONInteger(number)
	case "number":
		number, ok := value.(json.Number)
		if !ok {
			return false
		}
		parsed, err := number.Float64()
		return err == nil &&
			!math.IsInf(parsed, 0) &&
			!math.IsNaN(parsed)
	case "null":
		return value == nil
	default:
		return false
	}
}

// constrainedJSONInteger accepts JSON Schema's mathematical integer domain.
// Foundation decodes integral JSON decimal/exponent spellings into exact Int
// values, while the coordinator retains the source literal in json.Number.
func constrainedJSONInteger(number json.Number) bool {
	raw := number.String()
	if !strings.ContainsAny(raw, ".eE") {
		_, err := number.Int64()
		return err == nil
	}
	if strings.HasPrefix(raw, "-") {
		raw = strings.TrimPrefix(raw, "-")
	}
	_, err := constrainedExactNonnegativeInt(raw)
	return err == nil
}

func constrainedNonnegativeInt(raw any, fallback int) (int, error) {
	if raw == nil {
		return fallback, nil
	}
	number, ok := raw.(json.Number)
	if !ok {
		return 0, fmt.Errorf("not an integer")
	}
	return constrainedExactNonnegativeInt(number.String())
}

// constrainedExactNonnegativeInt parses a JSON number literal as an exact
// nonnegative machine integer. JSON Schema's integer domain is mathematical,
// not lexical: 1, 1.0, and 1e0 are the same integer, so integral decimal and
// exponent spellings must be accepted while any fractional remainder fails.
// The parse is a linear scan of the literal (no bignum): json.Number carries
// the raw request bytes unbounded, so a superlinear parse would hand an
// attacker free coordinator CPU per oversized literal. Mirrors the Rust
// sidecar's exact_nonnegative_usize.
func constrainedExactNonnegativeInt(raw string) (int, error) {
	errNotInt := fmt.Errorf("not a nonnegative integer")
	if raw == "" || raw[0] == '-' || raw[0] == '+' {
		return 0, errNotInt
	}
	coefficient, exponent := raw, 0
	if idx := strings.IndexAny(raw, "eE"); idx >= 0 {
		parsed, err := strconv.Atoi(raw[idx+1:])
		if err != nil {
			return 0, errNotInt
		}
		coefficient, exponent = raw[:idx], parsed
	}
	// Any magnitude beyond the literal's own digit count (plus the 64-bit
	// integer range) is unrepresentable; rejecting here also keeps the
	// arithmetic below overflow-free for adversarial exponents.
	if exponent > len(coefficient)+64 || exponent < -(len(coefficient)+64) {
		return 0, errNotInt
	}
	whole, fraction := coefficient, ""
	if idx := strings.IndexByte(coefficient, '.'); idx >= 0 {
		whole, fraction = coefficient[:idx], coefficient[idx+1:]
	}
	if whole == "" || !allASCIIDigits(whole) || !allASCIIDigits(fraction) {
		return 0, errNotInt
	}
	digits := whole + fraction
	scale := len(fraction) - exponent
	if scale > 0 {
		split := max(len(digits)-scale, 0)
		if strings.TrimLeft(digits[split:], "0") != "" {
			return 0, errNotInt
		}
		digits = digits[:split]
	}
	digits = strings.TrimLeft(digits, "0")
	if digits == "" {
		return 0, nil
	}
	if scale < 0 {
		// int64 max has 19 digits; reject before materializing the zeros.
		if len(digits)-scale > 19 {
			return 0, errNotInt
		}
		digits += strings.Repeat("0", -scale)
	}
	value, err := strconv.ParseInt(digits, 10, 64)
	if err != nil || value < 0 || uint64(value) > uint64(^uint(0)>>1) {
		return 0, errNotInt
	}
	return int(value), nil
}

func allASCIIDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func constrainedOptionalInt(raw any) (int, bool, error) {
	if raw == nil {
		return 0, false, nil
	}
	value, err := constrainedNonnegativeInt(raw, 0)
	return value, true, err
}
