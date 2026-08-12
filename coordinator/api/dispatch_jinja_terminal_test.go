package api

import (
	"log/slog"
	"net/http"
	"os"
	"testing"

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

func TestShouldStopFailover_JinjaReasonsStopWith422(t *testing.T) {
	for _, reason := range []string{"jinja_template", "jinja_channel_tags", "jinja_null_bridge"} {
		d := &dispatchState{
			s: newTestServerForDispatch(t), model: "m",
			lastErrCode:   500,
			lastErr:       "Runtime error: upper filter requires string",
			lastErrReason: reason,
		}
		if !d.shouldStopFailover() {
			t.Fatalf("%s: a jinja provider rejection must stop failover on the first attempt", reason)
		}
		if !d.terminalClientError {
			t.Fatalf("%s: jinja stop must latch terminalClientError", reason)
		}
		if d.terminalClientErrorCode != http.StatusUnprocessableEntity {
			t.Fatalf("%s: latched code = %d, want 422 (our classification, not the provider's raw 500)", reason, d.terminalClientErrorCode)
		}
		if d.terminalClientErrorReason != rejectionReasonTemplateRenderFailed {
			t.Fatalf("%s: ledger reason = %q, want %q", reason, d.terminalClientErrorReason, rejectionReasonTemplateRenderFailed)
		}
		if d.terminalClientErrorMessage != jinjaTerminalRejectMessage {
			t.Fatalf("%s: surfaced message = %q, want the curated model_capability text", reason, d.terminalClientErrorMessage)
		}
	}
}

// A plain provider 500 with no jinja reason must keep failing over exactly as
// before — the stop keys on the normalized REASON, never on the 500 status.
func TestShouldStopFailover_NonJinja500StillFailsOver(t *testing.T) {
	for _, reason := range []string{"", "provider_error", "model_load"} {
		d := &dispatchState{
			s: newTestServerForDispatch(t), model: "m",
			lastErrCode: 500, lastErr: "boom", lastErrReason: reason,
		}
		if d.shouldStopFailover() {
			t.Fatalf("reason %q: a non-jinja 500 must fail over, not stop", reason)
		}
		if d.terminalClientError {
			t.Fatalf("reason %q: must not latch terminalClientError", reason)
		}
	}
}

// Provider-cased / dashed variants normalize before matching (the wire value
// is produced by a different codebase and must not bypass the stop on casing).
func TestShouldStopFailover_JinjaReasonNormalizes(t *testing.T) {
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode: 500, lastErrReason: " Jinja-Template ",
	}
	if !d.shouldStopFailover() {
		t.Fatal("a cased/dashed jinja reason must still stop failover")
	}
	if d.terminalClientErrorCode != http.StatusUnprocessableEntity {
		t.Fatalf("latched code = %d, want 422", d.terminalClientErrorCode)
	}
}

// Kill switch: EIGENINFERENCE_JINJA_TERMINAL_REJECT=false restores the legacy
// fail-over-on-500 behavior (and must not latch anything).
func TestShouldStopFailover_JinjaKillSwitch(t *testing.T) {
	t.Setenv(envJinjaTerminalReject, "false")
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode: 500, lastErrReason: "jinja_template",
	}
	if d.shouldStopFailover() {
		t.Fatal("with the kill switch off, a jinja 500 must fall back to legacy failover")
	}
	if d.terminalClientError {
		t.Fatal("kill switch must not latch terminalClientError")
	}
}

// A jinja rejection observed from a speculative race LOSER (whose error is
// never written to d.lastErr) must latch via latchDeterministicLoser so the
// survivor's later transient error cannot resume the storm.
func TestLatchDeterministicLoser_JinjaReason(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		StatusCode:  500,
		Error:       "Runtime error: upper filter requires string",
		ErrorReason: "jinja_template",
	})
	if !d.terminalClientError || d.terminalClientErrorCode != http.StatusUnprocessableEntity {
		t.Fatalf("race-loser jinja must latch 422; got latched=%v code=%d", d.terminalClientError, d.terminalClientErrorCode)
	}
	if d.terminalClientErrorReason != rejectionReasonTemplateRenderFailed {
		t.Fatalf("ledger reason = %q, want %q", d.terminalClientErrorReason, rejectionReasonTemplateRenderFailed)
	}
	// Survivor reports a transient error that alone would NOT stop failover.
	d.lastErrCode = 0
	d.lastErr = "request rejected: queue full"
	if !d.shouldStopFailover() {
		t.Fatal("a latched race-loser jinja rejection must stop failover regardless of the survivor's error")
	}
}

// The race-loser mirror honors the kill switch too.
func TestLatchDeterministicLoser_JinjaKillSwitch(t *testing.T) {
	t.Setenv(envJinjaTerminalReject, "false")
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		StatusCode: 500, ErrorReason: "jinja_template",
	})
	if d.terminalClientError {
		t.Fatal("kill switch must disable the race-loser jinja latch")
	}
}

// 422 itself must remain failover-able (existing policy: the provider maps
// model-OUTPUT-validation faults to 422, which can recover on a re-sample) —
// the jinja stop keys on the REASON, and must not have widened the
// StatusCode stop set.
func TestShouldStopFailover_Plain422StillFailsOver(t *testing.T) {
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode: 422, lastErr: "model output was not valid JSON",
	}
	if d.shouldStopFailover() {
		t.Fatal("a plain 422 must keep failing over; only jinja_* reasons stop")
	}
}

// Route-outcome taxonomy: a jinja failure is recorded as class client_error
// WITHOUT AdmittedButFailed (not an admission mismatch, not a provider
// fault), while the row's ErrorReason PRESERVES the jinja_* value so the
// inference.error{reason:jinja_*} series keeps measuring real render
// failures.
func TestJinjaRouteOutcome_ClientErrorClassPreservesReason(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode:  500,
		Error:       "Runtime error: upper filter requires string",
		ErrorReason: "jinja_template",
	})
	if out.ErrorClass != errorClassClientError {
		t.Fatalf("class = %q, want %q", out.ErrorClass, errorClassClientError)
	}
	if out.AdmittedButFailed {
		t.Fatal("a jinja render failure must NOT set AdmittedButFailed")
	}
	if out.ErrorReason != errorReasonJinjaTemplate {
		t.Fatalf("reason = %q, want %q preserved on the row", out.ErrorReason, errorReasonJinjaTemplate)
	}

	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		lastErrCode: 500, lastErr: "upper filter requires string", lastErrReason: "jinja_template",
	}
	dout := d.providerFailedRoutingOutcome()
	if dout.ErrorClass != errorClassClientError || dout.AdmittedButFailed {
		t.Fatalf("providerFailedRoutingOutcome for jinja: class=%q admitted=%v, want client_error + not admitted", dout.ErrorClass, dout.AdmittedButFailed)
	}
	if dout.ErrorReason != errorReasonJinjaTemplate {
		t.Fatalf("providerFailedRoutingOutcome reason = %q, want %q", dout.ErrorReason, errorReasonJinjaTemplate)
	}
}

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
		if got := isJinjaTemplateErrorReason(reason); got != want {
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
				wantStatus := safeInferenceFailureStatus(tc.msg.FailureCode, tc.msg.ErrorReason, tc.msg.TerminalCause)
				if delivered.StatusCode != wantStatus {
					t.Errorf("delivered status = %d, want canonical %d", delivered.StatusCode, wantStatus)
				}
			default:
				t.Error("terminal error was not delivered to ErrorCh")
			}
		})
	}
}
