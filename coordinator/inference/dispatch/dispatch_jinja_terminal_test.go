package dispatch

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestShouldStopFailover_JinjaReasonsStopWith422(t *testing.T) {
	for _, reason := range []string{"jinja_template", "jinja_channel_tags", "jinja_null_bridge"} {
		d := &execution{
			s: newTestController(t), model: "m",
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
		if d.terminalClientErrorMessage != JinjaTerminalRejectMessage {
			t.Fatalf("%s: surfaced message = %q, want the curated model_capability text", reason, d.terminalClientErrorMessage)
		}
	}
}

// A plain provider 500 with no jinja reason must keep failing over exactly as
// before — the stop keys on the normalized REASON, never on the 500 status.
func TestShouldStopFailover_NonJinja500StillFailsOver(t *testing.T) {
	for _, reason := range []string{"", "provider_error", "model_load"} {
		d := &execution{
			s: newTestController(t), model: "m",
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
	d := &execution{
		s: newTestController(t), model: "m",
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
	d := &execution{
		s: newTestController(t), model: "m",
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
	d := &execution{s: newTestController(t), model: "m"}
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
	d := &execution{s: newTestController(t), model: "m"}
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
	d := &execution{
		s: newTestController(t), model: "m",
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
	out := attempt.PreCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		StatusCode:  500,
		Error:       "Runtime error: upper filter requires string",
		ErrorReason: "jinja_template",
	})
	if out.ErrorClass != attempt.ErrorClassClientError {
		t.Fatalf("class = %q, want %q", out.ErrorClass, attempt.ErrorClassClientError)
	}
	if out.AdmittedButFailed {
		t.Fatal("a jinja render failure must NOT set AdmittedButFailed")
	}
	if out.ErrorReason != attempt.ErrorReasonJinjaTemplate {
		t.Fatalf("reason = %q, want %q preserved on the row", out.ErrorReason, attempt.ErrorReasonJinjaTemplate)
	}

	d := &execution{
		s: newTestController(t), model: "m",
		lastErrCode: 500, lastErr: "upper filter requires string", lastErrReason: "jinja_template",
	}
	dout := d.providerFailedRoutingOutcome()
	if dout.ErrorClass != attempt.ErrorClassClientError || dout.AdmittedButFailed {
		t.Fatalf("providerFailedRoutingOutcome for jinja: class=%q admitted=%v, want client_error + not admitted", dout.ErrorClass, dout.AdmittedButFailed)
	}
	if dout.ErrorReason != attempt.ErrorReasonJinjaTemplate {
		t.Fatalf("providerFailedRoutingOutcome reason = %q, want %q", dout.ErrorReason, attempt.ErrorReasonJinjaTemplate)
	}
}
