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

// TestOrUptimeClass pins the stored-route-outcome → OR-uptime class mapping used
// by the /v1/admin/uptime aggregation. Expected values are the documented wire
// strings; the client-gone-after-commit INPUT uses the real shared constant so
// the trigger can never silently drift from the metric/route writer.
func TestOrUptimeClass(t *testing.T) {
	tests := []struct {
		name        string
		finalStatus string
		errorClass  string
		errorCode   int
		want        string
	}{
		{"clean success", "success", "", 200, "success"},
		{"partial success client gone after commit", "partial_success", errorClassClientGoneAfterCommitCompleted, 200, "cancelled"},
		{"partial success mid-stream failure", "partial_success", "provider_error_after_commit", 502, "mid_stream"},
		{"cancelled before response", "cancelled", "client_gone_before_response", 0, "cancelled"},
		{"queue timeout is rate limited", "timeout", "queue_timeout", 429, "rate_limited"},
		{"first chunk timeout", "timeout", "first_chunk_timeout", 504, "timeout"},
		{"error provider 5xx", "error", "provider_error", 503, "provider_5xx"},
		{"error 429 rate limited", "error", "", 429, "rate_limited"},
		{"error 400 client error", "error", "", 400, "client_error"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := orUptimeClass(tt.finalStatus, tt.errorClass, tt.errorCode); got != tt.want {
				t.Errorf("orUptimeClass(%q, %q, %d) = %q, want %q",
					tt.finalStatus, tt.errorClass, tt.errorCode, got, tt.want)
			}
		})
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
