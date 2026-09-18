package api

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
)

// validateTrialOutputLimits runs before the generic normalizer, which supports
// legacy coercions unsuitable for an irrevocable lifetime token allowance.
func validateTrialOutputLimits(parsed map[string]any) error {
	var limit int64
	for _, name := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens", "n"} {
		value, exists := parsed[name]
		if !exists {
			continue
		}
		n, valid := positiveTrialInteger(value)
		if !valid {
			return fmt.Errorf("%s must be a positive integer", name)
		}
		if name == "n" {
			if n != 1 {
				return fmt.Errorf("n must be 1")
			}
			continue
		}
		if limit != 0 && limit != n {
			return fmt.Errorf("output token limits must agree")
		}
		limit = n
	}
	return nil
}

func positiveTrialInteger(v any) (int64, bool) {
	var n int64
	switch v := v.(type) {
	case int:
		n = int64(v)
	case int64:
		n = v
	case json.Number:
		parsed, err := strconv.ParseInt(string(v), 10, 64)
		if err != nil {
			return 0, false
		}
		n = parsed
	case float64:
		// JSON float decoding cannot preserve all integers above 2^53.
		if math.IsNaN(v) || math.IsInf(v, 0) || math.Trunc(v) != v || v > 1<<53 {
			return 0, false
		}
		n = int64(v)
	default:
		return 0, false
	}
	return n, n > 0
}
