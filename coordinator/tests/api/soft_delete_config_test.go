package api_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
)

func TestSoftDeleteMutationsConfig(t *testing.T) {
	if (api.ServerConfig{}).SoftDeleteMutationsEnabled {
		t.Fatal("zero config enables soft-delete mutations")
	}
	for _, tc := range []struct {
		value string
		want  bool
	}{
		{"", false},
		{"false", false},
		{"invalid", false},
		{"true", true},
	} {
		t.Run(tc.value, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_SOFT_DELETE_MUTATIONS_ENABLED", tc.value)
			if got := api.ReadServerConfig().SoftDeleteMutationsEnabled; got != tc.want {
				t.Fatalf("soft-delete mutations enabled = %v, want %v", got, tc.want)
			}
		})
	}
}
