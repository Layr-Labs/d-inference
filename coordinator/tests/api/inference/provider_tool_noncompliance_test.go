package inference_test

import (
	"log/slog"
	"os"
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestToolNoncomplianceOutcomePreservesReason(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := routeoutcome.PreCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode:  422,
		Error:       "model did not emit the required tool call",
		ErrorReason: "tool_noncompliance",
		FailureCode: protocol.FailureCodeGenerationFailure,
	})
	if out.ErrorReason != failure.ErrorReasonToolNoncompliance {
		t.Fatalf("reason = %q, want %q on the route row", out.ErrorReason, failure.ErrorReasonToolNoncompliance)
	}
}

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
				FailureCode: protocol.FailureCodeGenerationFailure,
			},
			wantFailure: false,
		},
		{
			name: "wire-cased tool_noncompliance normalizes into the exemption",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "model emitted a tool call outside tool_choice",
				ErrorReason: " Tool-Noncompliance ",
				FailureCode: protocol.FailureCodeGenerationFailure,
			},
			wantFailure: false,
		},
		{
			name: "plain 422 with no structured reason still records a failure",
			msg: protocol.InferenceErrorMessage{
				StatusCode: 422, Error: "model output was not valid JSON",
				FailureCode: protocol.FailureCodeGenerationFailure,
			},
			wantFailure: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
			st := memory.NewMemory(store.Config{AdminKey: "test-key"})
			reg := registry.New(logger)
			srv := newComposedServer(reg, st, TestServerConfig{}, logger)
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
			srv.HandleInferenceError(provider.ID, provider, &msg)

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
				canonical, _, _ := failure.SanitizeProviderError(&delivered)
				wantStatus := canonical.StatusCode
				if delivered.StatusCode != wantStatus {
					t.Errorf("delivered status = %d, want canonical %d", delivered.StatusCode, wantStatus)
				}
			default:
				t.Error("terminal error was not delivered to ErrorCh")
			}
		})
	}
}
