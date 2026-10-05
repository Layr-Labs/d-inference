package failure_test

import (
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
)

// isJinjaTemplateErrorReason is the single normalization point shared by the
// dispatch stop, the reputation exemption, and the outcome taxonomy.
func TestIsJinjaTemplateErrorReason(t *testing.T) {
	for reason, want := range map[string]bool{
		"jinja_template":     true,
		"jinja_channel_tags": true,
		"jinja_null_bridge":  true,
		"Jinja-Template":     true,
		" jinja_template ":   true,
		"":                   false,
		"provider_error":     false,
		"model_load":         false,
		"tool_noncompliance": false,
		"jinja":              false,
	} {
		if got := failure.IsJinjaTemplateErrorReason(reason); got != want {
			t.Errorf("isJinjaTemplateErrorReason(%q) = %v, want %v", reason, got, want)
		}
	}
}
