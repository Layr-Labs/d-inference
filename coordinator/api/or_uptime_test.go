package api

import "testing"

// TestClassifyOutcomeByCode pins the HTTP-status → OR-uptime class mapping that
// implements OpenRouter's denominator rules: 429 is excluded (rate_limited),
// 504/408 are fetch timeouts, all other 5xx (and an unknown 0 code) count as
// provider failures, 4xx are excluded client errors, and 2xx is success.
func TestClassifyOutcomeByCode(t *testing.T) {
	tests := []struct {
		code int
		want string
	}{
		{429, "rate_limited"},
		{504, "timeout"},
		{408, "timeout"},
		{500, "provider_5xx"},
		{502, "provider_5xx"},
		{503, "provider_5xx"},
		{400, "client_error"},
		{401, "client_error"},
		{402, "client_error"},
		{403, "client_error"},
		{404, "client_error"},
		{413, "client_error"},
		{0, "provider_5xx"},
		{200, "success"},
	}
	for _, tt := range tests {
		if got := classifyOutcomeByCode(tt.code); got != tt.want {
			t.Errorf("classifyOutcomeByCode(%d) = %q, want %q", tt.code, got, tt.want)
		}
	}
}

// TestOrUptimeClassForRejection confirms a rejection's class is exactly the
// status-code classification (it is a thin wrapper over classifyOutcomeByCode).
func TestOrUptimeClassForRejection(t *testing.T) {
	for _, code := range []int{429, 503} {
		if got, want := orUptimeClassForRejection(code), classifyOutcomeByCode(code); got != want {
			t.Errorf("orUptimeClassForRejection(%d) = %q, want %q (classifyOutcomeByCode)", code, got, want)
		}
	}
}
