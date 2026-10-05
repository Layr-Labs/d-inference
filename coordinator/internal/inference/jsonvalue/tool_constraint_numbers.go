package jsonvalue

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// constrainedJSONInteger accepts JSON Schema's mathematical integer domain.
// Foundation decodes integral JSON decimal/exponent spellings into exact Int
// values, while the coordinator retains the source literal in json.Number.
func ConstrainedJSONInteger(number json.Number) bool {
	raw := number.String()
	if !strings.ContainsAny(raw, ".eE") {
		_, err := number.Int64()
		return err == nil
	}
	if strings.HasPrefix(raw, "-") {
		raw = strings.TrimPrefix(raw, "-")
	}
	_, err := ExactNonnegativeInt(raw)
	return err == nil
}

func ConstrainedNonnegativeInt(raw any, fallback int) (int, error) {
	if raw == nil {
		return fallback, nil
	}
	number, ok := raw.(json.Number)
	if !ok {
		return 0, fmt.Errorf("not an integer")
	}
	return ExactNonnegativeInt(number.String())
}

// constrainedExactNonnegativeInt parses a JSON number literal as an exact
// nonnegative machine integer. JSON Schema's integer domain is mathematical,
// not lexical: 1, 1.0, and 1e0 are the same integer, so integral decimal and
// exponent spellings must be accepted while any fractional remainder fails.
// The parse is a linear scan of the literal (no bignum): json.Number carries
// the raw request bytes unbounded, so a superlinear parse would hand an
// attacker free coordinator CPU per oversized literal. Mirrors the Rust
// sidecar's exact_nonnegative_usize.
func ExactNonnegativeInt(raw string) (int, error) {
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

func ConstrainedOptionalInt(raw any) (int, bool, error) {
	if raw == nil {
		return 0, false, nil
	}
	value, err := ConstrainedNonnegativeInt(raw, 0)
	return value, true, err
}
