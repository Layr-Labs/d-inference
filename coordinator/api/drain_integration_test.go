package api

// R2 (coordinator half) integration tests: drain awareness through the real
// HTTP + WebSocket path. A provider that reports heartbeat status "draining",
// or that refuses a dispatch with the typed error_reason "draining", is
// skipped by routing and counted as TRANSIENT capacity; the typed refusal
// consumes none of the request's transient-capacity retries and derates no
// gray-box capacity state for the pair. Legacy providers (untyped 503 →
// capacity_busy) keep today's bounded path — used here as the control.

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// sendHeartbeatStatus emits a heartbeat with the given status from the fake
// provider's socket (the same frame a Swift provider sends every ~30s).
func (fp *failoverProvider) sendHeartbeatStatus(t *testing.T, ctx context.Context, status string) {
	t.Helper()
	writeProviderJSON(t, ctx, fp.conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: status, Stats: protocol.HeartbeatStats{},
	})
}

// typedRejectScript refuses every dispatch pre-content with the typed
// capacity reason (draining or capacity_busy) as a 503 — the Swift drain
// admission rejection shape.
func typedRejectScript(reason string) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, reason, http.StatusServiceUnavailable)
	}
}

// TestDrain_HeartbeatStatusSkipsProvider: the fast provider A reports
// "draining"; the admission preflight counts it as transient capacity, the
// request is served by B without ever touching A, and an "idle" heartbeat
// restores A.
func TestDrain_HeartbeatStatusSkipsProvider(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "drain-heartbeat-model"

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.9.0", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.9.0", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	pA.sendHeartbeatStatus(t, ctx, protocol.HeartbeatStatusDraining)
	awaitCondition(t, 5*time.Second, func() bool { return reg.ProviderDraining(pA.registryID) }, "provider-a marked draining by its heartbeat")

	candidates, capacityRejections, tooLarge := reg.QuickCapacityCheck(model, 500, 64, registry.RequestTraits{})
	if candidates != 1 || capacityRejections != 1 || tooLarge != 0 {
		t.Errorf("QuickCapacityCheck = (%d, %d, %d), want (1, 1, 0): B routable, A transient", candidates, capacityRejections, tooLarge)
	}

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("provider-b"))
	if got := pA.dispatchCount(); got != 0 {
		t.Errorf("draining provider-a received %d dispatch(es), want 0", got)
	}

	pA.sendHeartbeatStatus(t, ctx, "idle")
	awaitCondition(t, 5*time.Second, func() bool { return !reg.ProviderDraining(pA.registryID) }, "provider-a drain cleared by an idle heartbeat")
	status, body, err = postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request after drain cleared: %v", err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("provider-a"))
	if got := pB.dispatchCount(); got != 1 {
		t.Errorf("provider-b dispatches = %d, want 1", got)
	}
}

// TestDrain_TypedRejection_NoRetryChargeNoDerate: four draining providers
// outrank the one serving box. Each refuses once with the typed "draining"
// reason and is marked draining (never re-dispatched); the request keeps
// failing over WITHOUT spending its 3 transient-capacity retries and lands on
// the serving box on attempt 5. No draining pair is capacity-cooled or
// budget-clamped. The capacity_busy control below shows the bounded path
// this deliberately does not take.
func TestDrain_TypedRejection_NoRetryChargeNoDerate(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "drain-typed-model"

	draining := make([]*failoverProvider, 0, 4)
	for i, tps := range []float64{200, 150, 100, 50} {
		draining = append(draining, startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: "draining-" + strings.Repeat("x", i+1), Version: "0.9.0", DecodeTPS: tps,
			Models: []failoverModelSpec{{ID: model}}, Script: typedRejectScript(errorReasonDraining),
		}))
	}
	serving := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "serving", Version: "0.9.0", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("serving"))
	if got := serving.dispatchCount(); got != 1 {
		t.Errorf("serving dispatches = %d, want 1", got)
	}
	total := 0
	for _, fp := range draining {
		n := fp.dispatchCount()
		total += n
		if n != 1 {
			t.Errorf("%s dispatches = %d, want exactly 1 (skipped after its typed draining refusal)", fp.name, n)
		}
		if !reg.ProviderDraining(fp.registryID) {
			t.Errorf("%s not marked draining after its typed refusal", fp.name)
		}
		if reg.CapacityCooldownActive(fp.registryID, model) {
			t.Errorf("%s: capacity-reject cooldown active — a drain refusal must not feed the black-hole cooldown", fp.name)
		}
		if reg.BudgetClampActive(fp.registryID, model) {
			t.Errorf("%s: budget clamp armed — a drain refusal must not derate the pair", fp.name)
		}
	}
	if total != 4 {
		t.Errorf("draining dispatches = %d, want 4 (one per provider; more than 3 proves no capacity retry was charged)", total)
	}

	// The marked providers stay excluded for the next request too — no
	// heartbeat status needed.
	status, body, err = postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("second chat request: %v", err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("serving"))
	for _, fp := range draining {
		if n := fp.dispatchCount(); n != 1 {
			t.Errorf("%s dispatches after second request = %d, want 1", fp.name, n)
		}
	}
}

// TestDrain_LegacyCapacityBusyControl_StillBounded: the same topology with
// the legacy typed reason capacity_busy: each refusal charges a transient-
// capacity retry, so the ladder stops after maxCapacityClassRetries with an
// uptime-neutral 429 and never reaches the serving box — the behavior the
// draining reason is exempted from.
func TestDrain_LegacyCapacityBusyControl_StillBounded(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "drain-control-model"

	busy := make([]*failoverProvider, 0, 4)
	for i, tps := range []float64{200, 150, 100, 50} {
		busy = append(busy, startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: "busy-" + strings.Repeat("x", i+1), Version: "0.9.0", DecodeTPS: tps,
			Models: []failoverModelSpec{{ID: model}}, Script: typedRejectScript(errorReasonCapacityBusy),
		}))
	}
	serving := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "serving", Version: "0.9.0", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 after %d capacity_busy refusals; body = %s", status, maxCapacityClassRetries, body)
	}
	if got := serving.dispatchCount(); got != 0 {
		t.Errorf("serving dispatches = %d, want 0 (the bounded ladder stopped first)", got)
	}
	total := 0
	for _, fp := range busy {
		total += fp.dispatchCount()
		if reg.ProviderDraining(fp.registryID) {
			t.Errorf("%s marked draining by a capacity_busy refusal", fp.name)
		}
	}
	if total != maxCapacityClassRetries {
		t.Errorf("busy dispatches = %d, want %d (one per charged capacity retry)", total, maxCapacityClassRetries)
	}
}

// TestDrain_TypedRejectionClearedByIdleHeartbeat: a provider whose drain the
// coordinator learned from the typed rejection alone (its "draining" event
// heartbeat never landed) reports idle once the drain aborts — the mark
// clears on that heartbeat and the provider is routable again, rather than
// staying excluded until the 150 s TTL.
func TestDrain_TypedRejectionClearedByIdleHeartbeat(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "drain-idle-heartbeat-model"

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.9.0", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: typedRejectScript(errorReasonDraining),
	})
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.9.0", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("provider-b"))
	if !reg.ProviderDraining(pA.registryID) {
		t.Fatalf("provider-a not marked draining after its typed refusal")
	}

	before := reg.GetProvider(pA.registryID)
	before.Mu().Lock()
	lastHB := before.LastHeartbeat
	before.Mu().Unlock()
	pA.sendHeartbeatStatus(t, ctx, "idle")
	awaitCondition(t, 5*time.Second, func() bool {
		p := reg.GetProvider(pA.registryID)
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.LastHeartbeat.After(lastHB)
	}, "idle heartbeat processed")
	if reg.ProviderDraining(pA.registryID) {
		t.Fatalf("rejection-set drain mark survived the provider's idle heartbeat")
	}

	// Routable again: the fast box is selected first and (still scripted to
	// refuse) types the reason once more, re-marking itself for exactly one
	// bounce before B serves.
	status, body, err = postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("second chat request: %v", err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("provider-b"))
	if got := pA.dispatchCount(); got != 2 {
		t.Errorf("provider-a dispatches = %d, want 2 (routable again after the idle heartbeat)", got)
	}
	if !reg.ProviderDraining(pA.registryID) {
		t.Fatalf("second typed refusal did not re-mark provider-a draining")
	}
}
