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

// E5: providers map a forced-tool_choice violation ("model did not emit the
// required tool call" / "outside tool_choice" / "deferred content limit") to a
// typed 422 with error_reason "tool_noncompliance". The coordinator must
// accept the reason into durable telemetry (whitelist) and keep the 422 on the
// normal bounded-failover path — a re-sample can comply.

// handleInferenceError must NOT record a reputation failure for a
// tool_noncompliance 422 — the MODEL's output, not the provider, broke the
// forced tool_choice contract (mirrors the jinja_* exemption in
// TestHandleInferenceError_JinjaSkipsRecordJobFailure). A plain 422 with no
// structured reason still counts, so the exemption cannot over-widen.
// The tool_noncompliance case FAILS without the isNonProviderFaultErrorReason
// exemption in handleInferenceError.
func TestHandleInferenceError_ToolNoncomplianceSkipsRecordJobFailure(t *testing.T) {
	cases := []struct {
		name        string
		msg         protocol.InferenceErrorMessage
		wantFailure bool
	}{
		{
			name: "tool_noncompliance 422 is exempt",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "model did not emit the required tool call",
				ErrorReason: "tool_noncompliance",
			},
			wantFailure: false,
		},
		{
			name: "wire-cased tool_noncompliance normalizes into the exemption",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "model emitted a tool call outside tool_choice",
				ErrorReason: " Tool-Noncompliance ",
			},
			wantFailure: false,
		},
		{
			name: "plain 422 with no structured reason still records a failure",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "model output was not valid JSON",
			},
			wantFailure: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
			st := store.NewMemory(store.Config{AdminKey: "test-key"})
			reg := registry.New(logger)
			srv := NewServer(reg, st, ServerConfig{}, logger)
			provider := reg.Register("provider-toolnc-"+tc.name, nil, &protocol.RegisterMessage{
				Type:     protocol.TypeRegister,
				Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
				Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
				Backend:  "mlx-swift",
			})
			pr := &registry.PendingRequest{
				RequestID:  "req-toolnc",
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
				wantStatus := attempt.SafeInferenceFailureStatus(
					delivered.FailureCode, delivered.ErrorReason, delivered.TerminalCause, delivered.StatusCode)
				if delivered.StatusCode != wantStatus {
					t.Errorf("delivered status = %d, want canonical %d", delivered.StatusCode, wantStatus)
				}
			default:
				t.Error("terminal error was not delivered to ErrorCh")
			}
		})
	}
}
