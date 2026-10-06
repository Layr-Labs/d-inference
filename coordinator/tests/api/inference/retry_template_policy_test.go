package inference_test

import (
	"log/slog"
	"net/http"
	"os"
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	retry "github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestShouldStopFailover_JinjaReasonsStopWith422(t *testing.T) {
	for _, reason := range []string{"jinja_template", "jinja_channel_tags", "jinja_null_bridge"} {
		c := retry.New(retry.Config{Model: "m"})
		d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 500, Error: "Runtime error: upper filter requires string", ErrorReason: reason}, 0)
		if !d.Stop {
			t.Fatalf("%s: a jinja provider rejection must stop failover on the first attempt", reason)
		}
		if d.ClientStatusCode == 0 {
			t.Fatalf("%s: jinja stop must latch terminalClientError", reason)
		}
		if d.ClientStatusCode != http.StatusUnprocessableEntity {
			t.Fatalf("%s: latched code = %d, want 422 (our classification, not the provider's raw 500)", reason, d.ClientStatusCode)
		}
		if d.ClientReason != "template_render_failed" {
			t.Fatalf("%s: ledger reason = %q, want %q", reason, d.ClientReason, "template_render_failed")
		}
		if d.ClientMessage != retry.TemplateRejectMessage {
			t.Fatalf("%s: surfaced message = %q, want the curated model_capability text", reason, d.ClientMessage)
		}
	}
}

// A plain provider 500 with no jinja reason must keep failing over exactly as
// before — the stop keys on the normalized REASON, never on the 500 status.
func TestShouldStopFailover_NonJinja500StillFailsOver(t *testing.T) {
	for _, reason := range []string{"", "provider_error", "model_load"} {
		c := retry.New(retry.Config{Model: "m"})
		d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 500, Error: "boom", ErrorReason: reason}, 0)
		if d.Stop {
			t.Fatalf("reason %q: a non-jinja 500 must fail over, not stop", reason)
		}
		if d.ClientStatusCode != 0 {
			t.Fatalf("reason %q: must not latch terminalClientError", reason)
		}
	}
}

// Provider-cased / dashed variants normalize before matching (the wire value
// is produced by a different codebase and must not bypass the stop on casing).
func TestShouldStopFailover_JinjaReasonNormalizes(t *testing.T) {
	c := retry.New(retry.Config{Model: "m"})
	d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 500, ErrorReason: " Jinja-Template "}, 0)
	if !d.Stop {
		t.Fatal("a cased/dashed jinja reason must still stop failover")
	}
	if d.ClientStatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("latched code = %d, want 422", d.ClientStatusCode)
	}
}

// Kill switch: EIGENINFERENCE_JINJA_TERMINAL_REJECT=false restores the legacy
// fail-over-on-500 behavior (and must not latch anything).
func TestShouldStopFailover_JinjaKillSwitch(t *testing.T) {
	t.Setenv(retry.TemplateRejectEnv, "false")
	c := retry.New(retry.Config{Model: "m"})
	d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 500, ErrorReason: "jinja_template"}, 0)
	if d.Stop {
		t.Fatal("with the kill switch off, a jinja 500 must fall back to legacy failover")
	}
	if d.ClientStatusCode != 0 {
		t.Fatal("kill switch must not latch terminalClientError")
	}
}

// A jinja rejection observed from a speculative race LOSER (whose error is
// never written to d.lastErr) must latch via latchDeterministicLoser so the
// survivor's later transient error cannot resume the storm.
func TestLatchDeterministicLoser_JinjaReason(t *testing.T) {
	c := retry.New(retry.Config{Model: "m"})
	d, _ := c.RecordLoser(protocol.InferenceErrorMessage{
		StatusCode:  500,
		Error:       "Runtime error: upper filter requires string",
		ErrorReason: "jinja_template",
		FailureCode: protocol.FailureCodeTemplateRender,
	}, 0)
	if d.ClientStatusCode == 0 || d.ClientStatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("race-loser jinja must latch 422; got latched=%v code=%d", d.ClientStatusCode != 0, d.ClientStatusCode)
	}
	if d.ClientReason != "template_render_failed" {
		t.Fatalf("ledger reason = %q, want %q", d.ClientReason, "template_render_failed")
	}
	// Survivor reports a transient error that alone would NOT stop failover.
	if !c.Decide(protocol.InferenceErrorMessage{StatusCode: 0, Error: "request rejected: queue full"}, 0).Stop {
		t.Fatal("a latched race-loser jinja rejection must stop failover regardless of the survivor's error")
	}
}

// The race-loser mirror honors the kill switch too.
func TestLatchDeterministicLoser_JinjaKillSwitch(t *testing.T) {
	t.Setenv(retry.TemplateRejectEnv, "false")
	c := retry.New(retry.Config{Model: "m"})
	d, _ := c.RecordLoser(protocol.InferenceErrorMessage{
		StatusCode: 500, ErrorReason: "jinja_template",
		FailureCode: protocol.FailureCodeTemplateRender,
	}, 0)
	if d.ClientStatusCode != 0 {
		t.Fatal("kill switch must disable the race-loser jinja latch")
	}
}

// 422 itself must remain failover-able (existing policy: the provider maps
// model-OUTPUT-validation faults to 422, which can recover on a re-sample) —
// the jinja stop keys on the REASON, and must not have widened the
// StatusCode stop set.
func TestShouldStopFailover_Plain422StillFailsOver(t *testing.T) {
	c := retry.New(retry.Config{Model: "m"})
	d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 422, Error: "model output was not valid JSON"}, 0)
	if d.Stop {
		t.Fatal("a plain 422 must keep failing over; only jinja_* reasons stop")
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
			st := memory.NewMemory(store.Config{AdminKey: "test-key"})
			reg := registry.New(logger)
			srv := newComposedServer(reg, st, TestServerConfig{}, logger)
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
				canonical, _, _ := failure.SanitizeProviderError(&tc.msg)
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
