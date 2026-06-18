package api

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// HTTP-level regression for the gemma-4 over-admission fix: a fleet whose only
// provider decodes BELOW the per-request floor (but has ample KV budget, so the
// memory gate passes) must be SHED with an immediate 429 when decode-floor
// hard-shed is armed — even under the default queue-before-shed=true. Without
// the consumer-side coupling (DecodeFloorShedArmed bypassing queue-before-shed),
// the request would instead queue and time out — the production symptom.

// connectSlowDecodeProvider registers a provider with a large KV budget (memory
// gate wide open) but a low observed decode TPS (below the floor under load).
func connectSlowDecodeProvider(
	t *testing.T, ctx context.Context, tsURL, model string, observedTPS float64,
) *websocket.Conn {
	t.Helper()
	conn := connectProvider(t, ctx, tsURL,
		[]protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		testPublicKeyB64())
	return conn
}

func TestDecodeFloorHardShedReturns429UnderDefaultQueueBeforeShed(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	// Defaults that previously made this stall: queue-before-shed ON. The fix
	// must shed anyway because decode-floor hard-shed is armed.
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	reg.SetDecodeFloorShed(15, true) // arm the throughput shed at 15 tok/s

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()

	model := "gemma-slow-http"
	conn := connectSlowDecodeProvider(t, ctx, ts.URL, model, 8)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	// KV budget wide open (memory gate passes), but observed decode 8 tok/s ⇒
	// projected per-request TPS is below the 15 floor.
	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			MaxConcurrency:        8,
			ActiveTokenBudgetUsed: 1_000,
			ActiveTokenBudgetMax:  1_000_000,
			ObservedDecodeTPS:     8,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil &&
			p.BackendCapacity.Slots[0].ObservedDecodeTPS == 8
	})

	status, body, err := adaptiveChatRequest(ctx, ts.URL, model, 256)
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (decode-floor shed), body = %s", status, body)
	}
	if !strings.Contains(body, "at capacity") {
		t.Fatalf("body = %s, want a capacity/429 error", body)
	}
}

func TestDecodeFloorShedDisabledStillQueuesSlowFleet(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	// Shed NOT armed (default). The same slow fleet must keep the pre-fix
	// behaviour: queue-before-shed queues the request (over-admission), not 429.
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	// reg.SetDecodeFloorShed not called ⇒ disabled.

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	model := "gemma-slow-noarm"
	conn := connectSlowDecodeProvider(t, ctx, ts.URL, model, 8)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			MaxConcurrency:        8,
			ActiveTokenBudgetUsed: 1_000,
			ActiveTokenBudgetMax:  1_000_000,
			ObservedDecodeTPS:     8,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil &&
			p.BackendCapacity.Slots[0].ObservedDecodeTPS == 8
	})

	// With shed disabled, a large-KV-budget slow fleet ADMITS (candidate passes
	// freeMemoryAdmits, decode floor advisory-only) — so the request dispatches
	// rather than 429'ing. We only assert it is NOT shed with a fast 429.
	reqCtx, reqCancel := context.WithCancel(ctx)
	defer reqCancel()
	done := make(chan int, 1)
	go func() {
		status, _, _ := adaptiveChatRequest(reqCtx, ts.URL, model, 256)
		done <- status
	}()
	// It should NOT come back as a fast 429 in the first moment.
	select {
	case status := <-done:
		if status == http.StatusTooManyRequests {
			t.Fatalf("got fast 429 with shed DISABLED; want admit/dispatch (no over-admission shedding)")
		}
	case <-time.After(750 * time.Millisecond):
		// Still in flight (dispatched/queued) — the expected non-shed path.
	}
	reqCancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		// best-effort cleanup; not a failure condition for this assertion
	}
}
