package dispatch

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/response"
)

func TestOpenRouterScoredDispatchEndpointExcludesGenericAPIs(t *testing.T) {
	tests := []struct {
		endpoint string
		want     bool
	}{
		{"", true},
		{"/v1/chat/completions", true},
		{"/v1/responses", true},
		{response.CompletionsEndpoint, false},
		{response.MessagesEndpoint, false},
	}
	for _, tt := range tests {
		if got := isOpenRouterScoredDispatchEndpoint(tt.endpoint); got != tt.want {
			t.Errorf("isOpenRouterScoredDispatchEndpoint(%q) = %v, want %v",
				tt.endpoint, got, tt.want)
		}
	}
}
