package api

import (
	"encoding/json"
	"math"
	"strconv"
)

// Validate every recognized top-level budget, even if another alias is positive.
// Omitted/null/zero and positive values keep their existing defaulting rules.
// Nested tool values are not inference budgets and must remain untouched.
func invalidOutputTokenField(parsed map[string]any) string {
	for _, field := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if value, present := parsed[field]; present && value != nil && !validOutputTokenNumber(value) {
			return field
		}
	}
	return ""
}

func validOutputTokenNumber(value any) bool {
	switch n := value.(type) {
	case json.Number:
		// Match integer budget parsing, without float rounding, truncation or
		// constructing arbitrary-precision values for unbounded exponents.
		integer, err := n.Int64()
		return err == nil && integer >= 0 && uint64(integer) <= uint64(^uint(0)>>1)
	case int:
		return n >= 0
	case int32:
		return n >= 0
	case int64:
		return n >= 0 && uint64(n) <= uint64(^uint(0)>>1)
	case float64:
		return n >= 0 && n < math.Exp2(strconv.IntSize-1) && n == math.Trunc(n)
	default:
		return false
	}
}
