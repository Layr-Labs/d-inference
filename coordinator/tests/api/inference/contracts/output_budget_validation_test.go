package inference_test

import (
	"encoding/json"
	"math"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func TestOutputTokenBudgetValidationRejectsAllInvalidAliases(t *testing.T) {
	for _, value := range []any{-1, int32(-2), int64(-3), float64(-0.5), float64(1.5), math.Inf(1), math.NaN(), "-1", true, []any{1}, map[string]any{}, json.Number("-1"), json.Number("1.5"), json.Number("-1e-9999"), json.Number("1e9999"), json.Number("9223372036854775808")} {
		for _, field := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
			parsed := map[string]any{"max_tokens": 64, "max_completion_tokens": 64, "max_output_tokens": 64}
			parsed[field] = value
			if bad := inreq.InvalidOutputTokenField(parsed); bad != field {
				t.Errorf("invalid %s=%v masked by another alias: got %q", field, value, bad)
			}
		}
	}
}
