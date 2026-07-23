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
		TerminalCause: terminalCauseAdmissionTimeout,
	}
}

// TestShouldStopFailover_TypedAdmissionTimeoutIsTransientCapacity: the typed
// cause must classify as transient capacity — bounded failover, then the
// uptime-neutral 429 — not walk the unbounded fault ladder to a 503.
func TestShouldStopFailover_TypedAdmissionTimeoutIsTransientCapacity(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.setLastInferenceError(nil, typedAdmissionTimeoutMsg())

	// Sanity: the fixed text alone would NOT classify as capacity (this is the
	// exact gap — remove the typed override and this test's premise breaks).
	if kind := classifyRejection(d.lastErrReason, d.lastErr, 0, 0); kind != rejectionNotCapacity {
		t.Fatalf("premise: bare admission_timeout text classified %v, want rejectionNotCapacity", kind)
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

// TestShouldStopFailover_LegacyAdmissionTextStaysFault pins the mixed-version
// contract: the SAME error text WITHOUT the typed cause (legacy provider)
// keeps the historical fault-failover classification. The typed field is the
// only thing that upgrades it.
func TestShouldStopFailover_LegacyAdmissionTextStaysFault(t *testing.T) {
	msg := typedAdmissionTimeoutMsg()
	msg.TerminalCause = ""
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.setLastInferenceError(nil, msg)

	if d.shouldStopFailover() {
		t.Fatal("legacy (untyped) admission text must keep fault failover, not stop")
	}
	if d.capacityRetries != 0 {
		t.Fatalf("capacityRetries = %d, want 0 for a legacy fault", d.capacityRetries)
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
