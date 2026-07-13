package api

import "testing"

func TestIsConsumerCancelTerminal(t *testing.T) {
	cases := []struct {
		name   string
		status int
		errMsg string
		want   bool
	}{
		{"bare 499", statusClientClosedRequest, "", true},
		{"499 with unrelated text", statusClientClosedRequest, "anything at all", true},
		{"overflow abort message, no status", 0, "request cancelled: consumer stream stalled (chunk buffer overflow)", true},
		{"provider cancel ack, 200", 200, "request cancelled", true},
		{"case-insensitive match", 500, "Request Cancelled by peer", true},
		{"provider disconnect 502", 502, "provider disconnected", false},
		{"genuine fault 500", 500, "model crashed during generation", false},
		{"capacity 503", 503, "token_budget_exhausted", false},
		{"empty", 0, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isConsumerCancelTerminal(tc.status, tc.errMsg); got != tc.want {
				t.Errorf("isConsumerCancelTerminal(%d, %q) = %v, want %v", tc.status, tc.errMsg, got, tc.want)
			}
		})
	}
}

func TestStatusClientClosedRequestValue(t *testing.T) {
	// The wire value is load-bearing (providers and consumers key off 499);
	// pin it so a refactor cannot silently change it.
	if statusClientClosedRequest != 499 {
		t.Fatalf("statusClientClosedRequest = %d, want 499", statusClientClosedRequest)
	}
}
