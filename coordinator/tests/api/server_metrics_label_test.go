package api_test

import (
	"testing"

	middleware "github.com/eigeninference/d-inference/coordinator/internal/api/middleware"
)

func TestHTTPPathLabel_UsesBoundedRouteLabel(t *testing.T) {
	tests := []struct {
		name  string
		route string
		want  string
	}{
		{name: "matched route", route: "POST /v1/chat/completions", want: "POST-/v1/chat/completions"},
		{name: "empty route", route: "", want: "unmatched"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := middleware.HTTPPathLabel(tt.route); got != tt.want {
				t.Fatalf("httpPathLabel(%q) = %q, want %q", tt.route, got, tt.want)
			}
		})
	}
}
