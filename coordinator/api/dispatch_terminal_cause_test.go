package api

// Regression tests for the PR review findings on typed-terminal handling in
// the dispatch ladder: the typed fields must survive setLastInferenceError so
// (1) a typed admission_timeout is classified as transient capacity by
// shouldStopFailover even though its fixed error text matches none of the
// legacy capacity substrings, and (2) typed attempt_usage reaches the failed
// attempt's route row on the ordinary (waitFirstChunk/waitAccepted) path,
// which builds its outcome from dispatch state rather than the standalone
// constructors.

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// typedAdmissionTimeoutMsg is shaped exactly like the Swift provider's typed
// admission-timeout terminal: 503, cause-prefixed human text that matches NO
// legacy capacity substring, and the typed cause field.
func typedAdmissionTimeoutMsg() protocol.InferenceErrorMessage {
	return protocol.InferenceErrorMessage{
		RequestID:     "req-1",
		Error:         "admission_timeout: admission lease expired before engine work began",
		StatusCode:    503,
		FailureCode:   protocol.FailureCodeCapacity,
		TerminalCause: terminalCauseAdmissionTimeout,
	}
}

// TestShouldStopFailover_TypedAdmissionTimeoutIsTransientCapacity: the typed
// cause must classify as transient capacity — bounded failover, then the
// uptime-neutral 429 — not walk the unbounded fault ladder to a 503.
func TestShouldStopFailover_TypedAdmissionTimeoutIsTransientCapacity(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.setLastInferenceError(nil, typedAdmissionTimeoutMsg())

	// The sanitizer derives a bounded capacity reason. Raw provider prose is
	// discarded and cannot participate in classification.
	if kind := classifyRejection(d.lastErrReason, d.lastErr, 0, 0); kind != rejectionTransientCapacity {
		t.Fatalf("typed admission timeout classified %v, want transient capacity", kind)
	}

	// Bounded transient-capacity failover: keep failing over below the cap…
	for i := 1; i < maxCapacityClassRetries; i++ {
		if d.shouldStopFailover() {
			t.Fatalf("attempt %d: transient capacity must keep failing over below the cap", i)
		}
		if d.unservable {
			t.Fatalf("attempt %d: must not latch unservable below the cap", i)
		}
	}
	// …and stop AT the cap with the unservable latch (→ single neutral 429).
	if !d.shouldStopFailover() {
		t.Fatalf("attempt %d: transient capacity must stop at maxCapacityClassRetries", maxCapacityClassRetries)
	}
	if !d.unservable {
		t.Fatal("capacity-cap stop must latch unservable (the 429 path), not a fault 503")
	}
	if d.terminalClientError {
		t.Fatal("admission_timeout is capacity, never a terminal client error")
	}
}

// TestShouldStopFailover_Legacy503UsesBoundedCapacityCompatibility pins the
// mixed-fleet contract: legacy prose is ignored, while bounded 503 status may
// select the capacity class during rolling upgrade.
func TestShouldStopFailover_Legacy503UsesBoundedCapacityCompatibility(t *testing.T) {
	msg := typedAdmissionTimeoutMsg()
	msg.TerminalCause = ""
	msg.FailureCode = ""
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.setLastInferenceError(nil, msg)

	if d.shouldStopFailover() {
		t.Fatal("legacy 503 capacity must keep bounded failover below the cap")
	}
	if d.capacityRetries != 1 {
		t.Fatalf("capacityRetries = %d, want 1 for legacy 503 capacity", d.capacityRetries)
	}
}

// TestProviderFailedRoutingOutcomeCarriesTypedAttemptUsage: the ordinary
// dispatch path's route-outcome builder must apply the usage retained by
// setLastInferenceError — on both the provider-fault branch and the
// deterministic client-error branch — and a following legacy error must clear
// it (no stale carryover between attempts).
func TestProviderFailedRoutingOutcomeCarriesTypedAttemptUsage(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	pr := &registry.PendingRequest{RequestID: "req-usage", Model: "m"}

	usage := &protocol.UsageInfo{PromptTokens: 123, CompletionTokens: 456, ReasoningTokens: 7}
	msg := protocol.InferenceErrorMessage{
		RequestID: "req-usage", Error: "safety_deadline: safety ceiling expired",
		StatusCode: 504, TerminalCause: terminalCauseSafetyDeadline, AttemptUsage: usage,
	}
	d.setLastInferenceError(nil, msg)

	out := d.providerFailedRoutingOutcomeFor(pr)
	if out.PromptTokens != 123 || out.CompletionTokens != 456 || out.ReasoningTokens != 7 {
		t.Fatalf("provider-fault branch: tokens = (%d,%d,%d), want (123,456,7)",
			out.PromptTokens, out.CompletionTokens, out.ReasoningTokens)
	}
	if !out.CompletionTokensSet {
		t.Fatal("CompletionTokensSet must be forced so a zero count is written, not skipped")
	}
	if out.CostMicroUSD != 0 {
		t.Fatalf("observability only: CostMicroUSD = %d, want 0", out.CostMicroUSD)
	}

	// Client-error branch (4xx) also carries the usage.
	msg4xx := msg
	msg4xx.StatusCode = 400
	d.setLastInferenceError(nil, msg4xx)
	if out := d.providerFailedRoutingOutcomeFor(pr); out.PromptTokens != 123 || !out.CompletionTokensSet {
		t.Fatalf("client-error branch dropped attempt usage: %+v", out)
	}

	// A later LEGACY error (no usage) must clear the retained usage — the next
	// attempt's row must not inherit attempt 1's tokens. (CompletionTokensSet
	// stays true: error rows force-persist an authoritative 0 vs NULL by
	// pre-existing design; carryover is checked by the VALUES.)
	d.setLastInferenceError(nil, protocol.InferenceErrorMessage{
		RequestID: "req-usage", Error: "boom", StatusCode: 500,
	})
	if out := d.providerFailedRoutingOutcomeFor(pr); out.PromptTokens != 0 ||
		out.CompletionTokens != 0 || out.ReasoningTokens != 0 {
		t.Fatalf("legacy follow-up must clear stale usage, got %+v", out)
	}
}

// TestSetLastErrorClearsTypedTerminalFields: a coordinator-synthesized error
// (timeout / no-provider / coordinator fault) replacing a typed provider
// terminal must clear the retained cause and usage — otherwise
// shouldStopFailover reclassifies the unrelated later failure as transient
// capacity (stale admission_timeout) and can latch the 429 path after mixed
// failures while more providers remain, and stale usage lands on the wrong
// attempt's route row.
func TestSetLastErrorClearsTypedTerminalFields(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	msg := typedAdmissionTimeoutMsg()
	msg.AttemptUsage = &protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 3}
	d.setLastInferenceError(nil, msg)
	if d.lastErrTerminalCause == "" || d.lastErrAttemptUsage == nil {
		t.Fatal("premise: typed fields must be retained from the provider terminal")
	}

	d.setLastError("timeout waiting for first response", 504)
	if d.lastErrTerminalCause != "" {
		t.Fatalf("synthetic error must clear the typed cause, got %q", d.lastErrTerminalCause)
	}
	if d.lastErrAttemptUsage != nil {
		t.Fatalf("synthetic error must clear the typed usage, got %+v", d.lastErrAttemptUsage)
	}
	// And the synthetic timeout must NOT classify as transient capacity.
	if d.shouldStopFailover() {
		t.Fatal("a synthetic timeout after a typed capacity terminal must keep fault failover")
	}
	if d.capacityRetries != 0 {
		t.Fatalf("capacityRetries = %d, want 0 — stale cause must not count capacity retries", d.capacityRetries)
	}
}

// TestTypedProvider504KeepsProviderErrorRouteClass: the wait loops' route
// defers use `504 && no typed cause` to mean a coordinator-synthesized
// timeout. A typed provider 504 (safety_deadline / backpressure_timeout) must
// instead flow through providerFailedRoutingOutcomeFor — keeping the
// provider_error class and its attempt usage — while an untyped 504 keeps the
// synthetic-timeout classification bit-for-bit.
func TestTypedProvider504KeepsProviderErrorRouteClass(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	pr := &registry.PendingRequest{RequestID: "req-504", Model: "m"}

	d.setLastInferenceError(nil, protocol.InferenceErrorMessage{
		RequestID: "req-504", Error: "safety_deadline: safety ceiling expired",
		StatusCode: 504, TerminalCause: terminalCauseSafetyDeadline,
		AttemptUsage: &protocol.UsageInfo{PromptTokens: 11, CompletionTokens: 2},
	})
	// The exact discriminator the wait-loop defers use:
	if d.lastErrCode == 504 && !isTypedTimeout504Cause(d.lastErrTerminalCause) {
		t.Fatal("typed 504 must NOT satisfy the synthetic-timeout discriminator")
	}
	out := d.providerFailedRoutingOutcomeFor(pr)
	if out.ErrorClass != "provider_error" {
		t.Fatalf("typed 504 route class = %q, want provider_error", out.ErrorClass)
	}
	if out.PromptTokens != 11 || out.CompletionTokens != 2 || !out.CompletionTokensSet {
		t.Fatalf("typed 504 must carry attempt usage, got %+v", out)
	}

	// Untyped (synthetic) 504 still satisfies the timeout discriminator.
	d.setLastError("timeout waiting for first response", 504)
	if !(d.lastErrCode == 504 && !isTypedTimeout504Cause(d.lastErrTerminalCause)) {
		t.Fatal("synthetic 504 must satisfy the synthetic-timeout discriminator")
	}

	// An unknown future cause is discarded and cannot preserve a provider-
	// selected 504. Without a valid code/cause this fails closed as canonical
	// generation_failure/500, distinct from coordinator-owned timeouts.
	d.setLastInferenceError(nil, protocol.InferenceErrorMessage{
		RequestID: "req-504", Error: "graceful_exit: node shutting down",
		StatusCode: 504, TerminalCause: "graceful_exit",
	})
	if d.lastErrCode != 500 || d.lastErrTerminalCause != "" {
		t.Fatalf("unknown-cause 504 must fail closed as generation/500, got code=%d cause=%q",
			d.lastErrCode, d.lastErrTerminalCause)
	}
	// And the two known typed 504 causes are exactly the exception set.
	if !isTypedTimeout504Cause(terminalCauseSafetyDeadline) ||
		!isTypedTimeout504Cause(terminalCauseBackpressureTimeout) {
		t.Fatal("safety_deadline and backpressure_timeout must be the typed 504 exceptions")
	}
	if isTypedTimeout504Cause(terminalCauseAdmissionTimeout) || isTypedTimeout504Cause("") {
		t.Fatal("only the two known 504 causes may bypass the timeout classification")
	}
}
