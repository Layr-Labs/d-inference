package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// C1: a deterministic provider client-shape 4xx must STOP failover immediately
// (return the code once) instead of walking up to maxDispatchAttempts providers.

func TestShouldStopFailover_ClientError400(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m", lastErrCode: 400, lastErr: "assistant message contains multiple tool_calls; Harmony supports one tool call per assistant message"}
	if !d.shouldStopFailover() {
		t.Fatal("a provider 400 must stop failover on the first attempt")
	}
	if !d.terminalClientError || d.terminalClientErrorCode != 400 {
		t.Fatalf("terminalClientError must latch with code 400; got latched=%v code=%d", d.terminalClientError, d.terminalClientErrorCode)
	}
}

func TestShouldStopFailover_413And415(t *testing.T) {
	for _, code := range []int{413, 415} {
		d := &dispatchState{s: newTestServerForDispatch(t), model: "m", lastErrCode: code}
		if !d.shouldStopFailover() {
			t.Fatalf("a provider %d must stop failover", code)
		}
		if d.terminalClientErrorCode != code {
			t.Fatalf("code %d must latch; got %d", code, d.terminalClientErrorCode)
		}
	}
}

// 422 (invalidResponseFormatOutput) is EXCLUDED from the stop set: it can be a
// model-output-validation fault that recovers on retry at temp>0, so it must keep
// failing over rather than be returned once.
func TestShouldStopFailover_422FailsOver(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m", lastErrCode: 422, lastErr: "model output was not valid JSON"}
	if d.shouldStopFailover() {
		t.Fatal("422 must fail over (may recover on retry), not stop")
	}
	if d.terminalClientError {
		t.Fatal("422 must NOT latch a terminal client error")
	}
}

// Reviewer-correction regression guard: 404 "model not loaded" is a cold-miss
// that MUST keep failing over (it also matches the "not loaded" capacity marker),
// so it must NOT be treated as a terminal client error.
func TestShouldStopFailover_ColdMiss404StillFailsOver(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m", lastErrCode: 404, lastErr: "Model 'm' is not loaded on this provider"}
	if d.shouldStopFailover() {
		t.Fatal("404 cold-miss must fail over to a provider that has the model loaded, not stop")
	}
	if d.terminalClientError {
		t.Fatal("404 must NOT latch a terminal client error")
	}
}

// 429 queue-full is transient capacity and must remain failover-able.
func TestShouldStopFailover_QueueFull429StillFailsOver(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m", lastErrCode: 429, lastErr: "request rejected: queue full"}
	if d.shouldStopFailover() {
		t.Fatal("429 queue-full must fail over (transient capacity), not stop")
	}
	if d.terminalClientError {
		t.Fatal("429 must NOT latch a terminal client error")
	}
}

// A client-shape 4xx observed from a speculative race LOSER (whose code is never
// written to d.lastErr) must latch via latchDeterministicLoser and then stop the
// loop — otherwise the storm resumes through the survivor's later transient error.
func TestLatchDeterministicLoser_ClientError400(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{StatusCode: 400, Error: "invalid tool payload"})
	if !d.terminalClientError || d.terminalClientErrorCode != 400 {
		t.Fatalf("race-loser 400 must latch terminalClientError; got latched=%v code=%d", d.terminalClientError, d.terminalClientErrorCode)
	}
	// Survivor reports a transient error that alone would NOT stop failover.
	d.lastErrCode = 0
	d.lastErr = "request rejected: queue full"
	if !d.shouldStopFailover() {
		t.Fatal("a latched race-loser client error must stop failover regardless of the survivor's error")
	}
}

// Kill switch: with the stop disabled, a 400 falls through to the legacy
// string-only classifyRejection path (here: not capacity → keep failing over).
func TestClientErrorStop_KillSwitch(t *testing.T) {
	s := newTestServerForDispatch(t)
	s.SetDisableClientErrorStop(true)
	d := &dispatchState{s: s, model: "m", lastErrCode: 400, lastErr: "invalid tool payload"}
	if d.shouldStopFailover() {
		t.Fatal("with the kill switch on, a 400 must not trigger the StatusCode stop")
	}
	if d.terminalClientError {
		t.Fatal("kill switch must not latch terminalClientError")
	}
}

// A client-shape failure is recorded as client_error WITHOUT AdmittedButFailed, so
// it never pollutes the admission-mismatch gauge; a genuine 5xx still does.
func TestClientErrorRouteOutcome_NotAdmittedButFailed(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "r1", Model: "m"}
	out := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{StatusCode: 400, Error: "invalid tool payload"})
	if out.ErrorClass != errorClassClientError {
		t.Fatalf("400 outcome class = %q, want %q", out.ErrorClass, errorClassClientError)
	}
	if out.AdmittedButFailed {
		t.Fatal("a client-shape 4xx must NOT set AdmittedButFailed")
	}
	if out.ErrorReason != errorReasonClientError {
		t.Fatalf("400 outcome reason = %q, want %q", out.ErrorReason, errorReasonClientError)
	}

	d := &dispatchState{s: newTestServerForDispatch(t), model: "m", lastErrCode: 400, lastErr: "invalid tool payload"}
	dout := d.providerFailedRoutingOutcome()
	if dout.ErrorClass != errorClassClientError || dout.AdmittedButFailed {
		t.Fatalf("providerFailedRoutingOutcome for 400: class=%q admitted=%v", dout.ErrorClass, dout.AdmittedButFailed)
	}

	// A genuine 5xx remains provider_error + AdmittedButFailed.
	fout := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{StatusCode: 500, Error: "boom"})
	if fout.ErrorClass != "provider_error" || !fout.AdmittedButFailed {
		t.Fatalf("500 outcome: class=%q admitted=%v, want provider_error + admitted", fout.ErrorClass, fout.AdmittedButFailed)
	}
}
