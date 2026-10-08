package api_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/responselimit"
)

func TestNonStreamingResponseLimitConfiguration(t *testing.T) {
	t.Setenv("EIGENINFERENCE_NONSTREAM_RESPONSE_MAX_BYTES", "4")
	t.Setenv("EIGENINFERENCE_NONSTREAM_RESPONSE_MAX_CHUNKS", "2")
	cfg := production.ReadServerConfig()
	limits := responselimit.Limits{MaxBytes: cfg.NonStreamingResponseMaxBytes, MaxChunks: cfg.NonStreamingResponseMaxChunks}
	b := limits.NewBudget(false)
	if !b.Accept(4) || !b.Accept(0) || b.Accept(0) {
		t.Fatal("configured limits not enforced")
	}
	if limits.NewBudget(true) != nil {
		t.Fatal("streaming incorrectly capped")
	}
	limits = responselimit.Limits{MaxBytes: -1, MaxChunks: -1}
	b = limits.NewBudget(false)
	if !b.Accept(responselimit.DefaultMaxBytes) || b.Accept(1) {
		t.Fatal("unsafe fallback")
	}
}
