package api

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// E5: providers map a forced-tool_choice violation ("model did not emit the
// required tool call" / "outside tool_choice" / "deferred content limit") to a
// typed 422 with error_reason "tool_noncompliance". The coordinator must
// accept the reason into durable telemetry (whitelist) and keep the 422 on the
// normal bounded-failover path — a re-sample can comply.

func TestToolNoncomplianceReasonIsWhitelisted(t *testing.T) {
	if got := normalizeInferenceErrorReason("tool_noncompliance"); got != errorReasonToolNoncompliance {
		t.Fatalf("normalizeInferenceErrorReason(tool_noncompliance) = %q, want %q (must not collapse to unknown)", got, errorReasonToolNoncompliance)
	}
	// Wire-casing variants normalize into the same reason.
	if got := normalizeInferenceErrorReason(" Tool-Noncompliance "); got != errorReasonToolNoncompliance {
		t.Fatalf("cased/dashed variant = %q, want %q", got, errorReasonToolNoncompliance)
	}
}

func TestToolNoncomplianceOutcomePreservesReason(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode:  422,
		Error:       "model did not emit the required tool call",
		ErrorReason: "tool_noncompliance",
	})
	if out.ErrorReason != errorReasonToolNoncompliance {
		t.Fatalf("reason = %q, want %q on the route row", out.ErrorReason, errorReasonToolNoncompliance)
	}
}

// isNonProviderFaultErrorReason is the shared vocabulary behind the
// reputation exemption (handleInferenceError) and the dispatch-path breaker
// exemption (noteProviderError): jinja_* + tool_noncompliance, nothing else.
func TestIsNonProviderFaultErrorReason(t *testing.T) {
	for reason, want := range map[string]bool{
		"jinja_template":         true,
		"jinja_channel_tags":     true,
		"jinja_null_bridge":      true,
		"tool_noncompliance":     true,
		" Tool-Noncompliance ":   true, // wire casing/dashes normalize
		"":                       false,
		"provider_error":         false,
		"client_error":           false, // generic client shape ≠ exonerating
		"model_load":             false, // load faults ARE provider faults
		"cancelled":              false, // cancel exemption is status/string-driven
		"token_budget_exhausted": false, // capacity exemption is status/string-driven
		"unknown":                false,
	} {
		if got := isNonProviderFaultErrorReason(reason); got != want {
			t.Errorf("isNonProviderFaultErrorReason(%q) = %v, want %v", reason, got, want)
		}
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
				ChunkCh:    make(chan string, 1),
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
				wantStatus := safeInferenceFailureStatus(
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

// The E4 jinja terminal stop must NOT catch a tool_noncompliance 422: the
// violation is output-dependent (another sample / provider can comply), so
// failover continues under the existing 422 policy.
func TestToolNoncompliance422RemainsFailoverable(t *testing.T) {
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode:   422,
		lastErr:       "model did not emit the required tool call",
		lastErrReason: "tool_noncompliance",
	}
	if d.shouldStopFailover() {
		t.Fatal("a tool_noncompliance 422 must keep failing over, not stop the ladder")
	}
	if d.terminalClientError {
		t.Fatal("tool_noncompliance must not latch a terminal client error")
	}
}
