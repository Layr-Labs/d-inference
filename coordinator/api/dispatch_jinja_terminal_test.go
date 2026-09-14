package api

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// E4 (2026-07-15 platform errors deep dive): a provider error_reason of
// jinja_channel_tags / jinja_null_bridge / jinja_template is a DETERMINISTIC
// template-render failure (the same body renders identically on every
// provider). The dispatch ladder must stop on the FIRST occurrence and latch
// a single 422 model_capability rejection — instead of failing over
// fleet-wide (prod: 1.57 dispatch rows per jinja request, observed up to 17)
// — and the provider must take no reputation hit for it.

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
		if got := attempt.IsJinjaTemplateErrorReason(reason); got != want {
			t.Errorf("isJinjaTemplateErrorReason(%q) = %v, want %v", reason, got, want)
		}
	}
}

// handleInferenceError must NOT record a reputation failure for a jinja_*
// terminal — the request shape, not the provider, is at fault. Capacity and
// cancel exemptions stay unchanged, and a plain 500 still counts.
func TestHandleInferenceError_JinjaSkipsRecordJobFailure(t *testing.T) {
	cases := []struct {
		name        string
		msg         protocol.InferenceErrorMessage
		wantFailure bool
	}{
		{
			name: "typed jinja_template is exempt",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "Runtime error: upper filter requires string",
				ErrorReason: "jinja_template", FailureCode: protocol.FailureCodeTemplateRender,
			},
			wantFailure: false,
		},
		{
			name: "typed jinja_channel_tags is exempt",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "template raised", ErrorReason: "jinja_channel_tags", FailureCode: protocol.FailureCodeTemplateRender,
			},
			wantFailure: false,
		},
		{
			name: "typed jinja_null_bridge is exempt",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "Cannot convert value", ErrorReason: "jinja_null_bridge", FailureCode: protocol.FailureCodeTemplateRender,
			},
			wantFailure: false,
		},
		{
			name:        "plain 500 still records a failure",
			msg:         protocol.InferenceErrorMessage{StatusCode: 500, Error: "boom", FailureCode: protocol.FailureCodeGenerationFailure},
			wantFailure: true,
		},
		{
			name:        "capacity 503 stays exempt",
			msg:         protocol.InferenceErrorMessage{StatusCode: 503, Error: "token_budget_exhausted: full", FailureCode: protocol.FailureCodeCapacity},
			wantFailure: false,
		},
		{
			name:        "cancel 499 stays exempt",
			msg:         protocol.InferenceErrorMessage{StatusCode: 499, Error: "request cancelled", FailureCode: protocol.FailureCodeCancelled},
			wantFailure: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
			st := store.NewMemory(store.Config{AdminKey: "test-key"})
			reg := registry.New(logger)
			srv := NewServer(reg, st, ServerConfig{}, logger)
			provider := reg.Register("provider-jinja-"+tc.name, nil, &protocol.RegisterMessage{
				Type:     protocol.TypeRegister,
				Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
				Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
				Backend:  "mlx-swift",
			})
			pr := &registry.PendingRequest{
				RequestID:  "req-jinja",
				Model:      "test-model",
				ChunkCh:    make(chan registry.ProviderChunk, 1),
				CompleteCh: make(chan protocol.UsageInfo, 1),
				ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
			}
			provider.AddPending(pr)

			msg := tc.msg
			msg.RequestID = pr.RequestID
			srv.handleInferenceError(provider.ID, provider, &msg)

			wantFailed := 0
			if tc.wantFailure {
				wantFailed = 1
			}
			if got := provider.Reputation.FailedJobs; got != wantFailed {
				t.Errorf("Reputation.FailedJobs = %d, want %d", got, wantFailed)
			}
			// The terminal is still delivered to the consumer channel either way.
			select {
			case delivered := <-pr.ErrorCh:
				wantStatus := attempt.SafeInferenceFailureStatus(tc.msg.FailureCode, tc.msg.ErrorReason, tc.msg.TerminalCause, tc.msg.StatusCode)
				if delivered.StatusCode != wantStatus {
					t.Errorf("delivered status = %d, want canonical %d", delivered.StatusCode, wantStatus)
				}
			default:
				t.Error("terminal error was not delivered to ErrorCh")
			}
		})
	}
}
