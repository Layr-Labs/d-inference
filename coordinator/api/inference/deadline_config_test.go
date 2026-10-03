package inference

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

func TestTTFTDeadlineExact(t *testing.T) {
	srv, _ := testServerWithConfig(t, TestServerConfig{FirstContentSLAAccounts: []string{testConsumerID}})
	tests := []struct {
		model       string
		inputTokens int
		want        time.Duration
	}{
		{model: "ordinary-model", inputTokens: 0, want: 5 * time.Second},
		{model: "ordinary-model", inputTokens: 1, want: 5*time.Second + time.Millisecond},
		{model: "ordinary-model", inputTokens: 5_000, want: 10 * time.Second},
		{model: "ordinary-model", inputTokens: 5_001, want: 10*time.Second + time.Millisecond},
		{model: modelpolicy.Qwen3VL30BA3BInstructModelID, inputTokens: 0, want: 4 * time.Second},
		{model: modelpolicy.Qwen3VL30BA3BInstructModelID, inputTokens: 1, want: 4*time.Second + time.Millisecond},
		{model: modelpolicy.Qwen3VL30BA3BInstructModelID + "-preview", inputTokens: 0, want: 5 * time.Second},
	}

	for _, tt := range tests {
		if got := srv.FirstContentDeadline(tt.model, tt.inputTokens); got != tt.want {
			t.Fatalf("FirstContentDeadline(%q, %d) = %v, want %v", tt.model, tt.inputTokens, got, tt.want)
		}
	}
}

func TestFirstContentDeadlineIsServerOwned(t *testing.T) {
	ordinary, _ := testServer(t)

	productionLike, _ := testServerWithConfig(t, TestServerConfig{
		FirstContentDeadlineBase: 9 * time.Second,
	})

	const promptTokens = 321
	if got, want := productionLike.FirstContentDeadline("ordinary-model", promptTokens), 9*time.Second+321*time.Millisecond; got != want {
		t.Fatalf("production-like deadline = %v, want %v", got, want)
	}
	if got, want := ordinary.FirstContentDeadline("ordinary-model", promptTokens), 5*time.Second+321*time.Millisecond; got != want {
		t.Fatalf("ordinary deadline changed by another server: got %v, want %v", got, want)
	}
	if got, want := productionLike.FirstContentDeadline(
		modelpolicy.Qwen3VL30BA3BInstructModelID, promptTokens,
	), 4*time.Second+321*time.Millisecond; got != want {
		t.Fatalf("Qwen3-VL production-like deadline = %v, want %v", got, want)
	}
}
