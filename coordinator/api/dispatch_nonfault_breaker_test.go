package api

// PR #548 review follow-up (Codex P2, dispatch.go ~1143): a jinja_* provider
// error arrives as a raw 500 — exactly the sickness shape the inference-error,
// node-health, and stable-identity breakers count — and the dispatch loop fed
// it to all three via noteDispatchProviderError BEFORE the E4 relabel in
// shouldStopFailover ran. A few malformed tool histories could therefore
// quarantine healthy providers/pairs. The dispatch funnel (noteProviderError)
// now withholds the provider for non-provider-fault reasons
// (isNonProviderFaultErrorReason: jinja_* + tool_noncompliance), while
// keeping the refund + held-chunk side effects and leaving every
// capacity-class rejection (which the capacity cooldown legitimately keys on)
// untouched.

import (
	"log/slog"
	"net/http"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// newBreakerExemptionHarness builds a server with one registered provider that
// carries a stable identity (AccountID), so all three provider-fault breakers
// AND the stable-identity ejection breaker are armed for the test.
func newBreakerExemptionHarness(t *testing.T, name string) (*Server, *registry.Registry, *registry.Provider, *registry.PendingRequest) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	provider := reg.Register("provider-"+name, nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})
	provider.Mu().Lock()
	provider.AccountID = "acct-" + name
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: "req-" + name,
		Model:     "test-model",
	}
	return srv, reg, provider, pr
}

// assertBreakerStates asserts the open/closed state of the three
// provider-fault breakers the dispatch funnel feeds, one assert per breaker so
// a regression names the exact breaker that tripped.
func assertBreakerStates(t *testing.T, reg *registry.Registry, provider *registry.Provider, pr *registry.PendingRequest, wantOpen bool) {
	t.Helper()
	if got := reg.InferenceErrorCooldownActive(provider.ID, pr.Model, pr.Traits.CooldownShape()); got != wantOpen {
		t.Errorf("inference-error pair cooldown active = %v, want %v", got, wantOpen)
	}
	if got := reg.ProviderBreakerOpen(provider.ID); got != wantOpen {
		t.Errorf("node-health breaker open = %v, want %v", got, wantOpen)
	}
	sid := reg.GetProviderStableIdentity(provider.ID)
	if sid == "" {
		t.Fatal("test provider must carry a stable identity (AccountID) so the ejection breaker is armed")
	}
	if got := reg.HealthEjectionOpen(sid); got != wantOpen {
		t.Errorf("stable-identity ejection open = %v, want %v", got, wantOpen)
	}
}

// breakerStrikeRounds comfortably exceeds every trip threshold involved:
// inference-error cooldown (2 strikes in window), node-health breaker
// (5 consecutive faults), stable-identity ejection (8 consecutive faults).
const breakerStrikeRounds = 10

// A jinja_* 500 must feed NONE of the provider-fault breakers: the template
// renders the same request body identically on every provider, so the fault
// belongs to the request, not the node. Fails without the noteProviderError
// reason gate on all three asserts (a raw 500 trips each breaker at its
// threshold). Fed through noteDispatchRetry — the dominant dispatch funnel —
// so the gate is proven on the wrapped path, not just the helper.
func TestNoteDispatchRetry_JinjaSkipsProviderFaultBreakers(t *testing.T) {
	srv, reg, provider, pr := newBreakerExemptionHarness(t, "jinja-skip")
	d := &dispatchState{s: srv, model: pr.Model}
	for range breakerStrikeRounds {
		d.noteDispatchRetry(provider, pr, http.StatusInternalServerError,
			"Runtime error: upper filter requires string", "jinja_template", nil)
	}
	assertBreakerStates(t, reg, provider, pr, false)
}

// The non-breaker side effects must survive the reason gate: the attempt's
// reservation top-up is still refunded and held boilerplate is still
// discarded (returning true so callers skip the generic retry counter).
func TestNoteProviderError_JinjaKeepsRefundAndHeldDiscard(t *testing.T) {
	srv, _, provider, pr := newBreakerExemptionHarness(t, "jinja-side-effects")
	pr.ConsumerKey = "consumer-key"
	pr.BaseReservedMicroUSD = 1_000
	pr.ReservedMicroUSD = 1_500 // provider-specific top-up to refund
	d := &dispatchState{s: srv, model: pr.Model}
	held := []string{`data: {"choices":[{"delta":{"role":"assistant"}}]}`}
	if !d.noteProviderError(provider, pr, http.StatusInternalServerError,
		"Runtime error: upper filter requires string", "jinja_template", &held) {
		t.Error("held boilerplate must still be discarded (return true) for an exempt reason")
	}
	if len(held) != 0 {
		t.Errorf("held chunks = %d, want 0 (discarded)", len(held))
	}
	if pr.ReservedMicroUSD != pr.BaseReservedMicroUSD {
		t.Errorf("ReservedMicroUSD = %d, want base %d (top-up refunded)", pr.ReservedMicroUSD, pr.BaseReservedMicroUSD)
	}
}

// tool_noncompliance is gated too, for consistency with the reputation
// exemption (handleInferenceError): the MODEL's output broke the forced
// tool_choice contract. Its 422 is already code-neutral in all three breakers
// today, so this documents (and pins) the intended end state rather than
// fixing a live trip — if a future provider version ever surfaced the reason
// on a 5xx, the gate keeps it out of the breakers.
func TestNoteDispatchRetry_ToolNoncomplianceSkipsProviderFaultBreakers(t *testing.T) {
	srv, reg, provider, pr := newBreakerExemptionHarness(t, "toolnc-skip")
	d := &dispatchState{s: srv, model: pr.Model}
	for range breakerStrikeRounds {
		d.noteDispatchRetry(provider, pr, http.StatusUnprocessableEntity,
			"model did not emit the required tool call", "tool_noncompliance", nil)
	}
	assertBreakerStates(t, reg, provider, pr, false)
}

// Control: a plain 500 with no exonerating reason still feeds all three
// breakers through the same funnel — the gate must not widen into a blanket
// breaker bypass. Fed through noteProviderError directly (the race-site
// funnel), covering the second call path.
func TestNoteProviderError_Plain500StillFeedsBreakers(t *testing.T) {
	srv, reg, provider, pr := newBreakerExemptionHarness(t, "plain-500")
	d := &dispatchState{s: srv, model: pr.Model}
	for range breakerStrikeRounds {
		d.noteProviderError(provider, pr, http.StatusInternalServerError, "boom", "", nil)
	}
	assertBreakerStates(t, reg, provider, pr, true)
}

// Guard for the "do not skip capacity cooldowns" constraint: a capacity-class
// 503 — whose structured reason (token_budget_exhausted) is deliberately NOT
// in the non-provider-fault vocabulary — must keep feeding the capacity-reject
// cooldown through the gated funnel, so black-hole detection still works.
func TestNoteProviderError_Capacity503StillFeedsCapacityCooldown(t *testing.T) {
	srv, reg, provider, pr := newBreakerExemptionHarness(t, "capacity-503")
	d := &dispatchState{s: srv, model: pr.Model}
	// Default capacity cooldown threshold is 5 strikes with zero interleaved
	// accepts; feed a couple beyond it.
	for range 7 {
		d.noteProviderError(provider, pr, http.StatusServiceUnavailable,
			"token_budget_exhausted: insufficient KV headroom", "token_budget_exhausted", nil)
	}
	if !reg.CapacityCooldownActive(provider.ID, pr.Model) {
		t.Error("capacity-reject cooldown must still trip for capacity-class 503s (reason gate must key on jinja_*/tool_noncompliance only)")
	}
	// And the fault breakers stay closed for capacity sheds, as before.
	if reg.ProviderBreakerOpen(provider.ID) {
		t.Error("node-health breaker must ignore capacity-class 503s (healthy shed)")
	}
}
