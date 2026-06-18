package api

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// capacityShedReason must distinguish a decode-floor (throughput) shed from an
// ordinary full-fleet rejection so the shed is observable in telemetry on its
// own reason_code/outcome — the lesson from the gemma incident (only mitigations
// with distinct reason codes were diagnosable).
func TestCapacityShedReasonDistinguishesThroughputShed(t *testing.T) {
	reason, outcome := capacityShedReason(true)
	if reason != "decode_floor_shed" || outcome != "decode_floor_shed" {
		t.Fatalf("throughput shed: got reason=%q outcome=%q, want decode_floor_shed/decode_floor_shed", reason, outcome)
	}
	reason, outcome = capacityShedReason(false)
	if reason != "machine_busy" || outcome != "capacity_429" {
		t.Fatalf("ordinary capacity: got reason=%q outcome=%q, want machine_busy/capacity_429", reason, outcome)
	}
}

// pureThroughputShed: bypass queue-before-shed ONLY when the shed is armed AND
// every capacity rejection is a throughput shed. A fast-but-full fleet
// (decodeFloorRejections < capacityRejections) must keep queueing.
func TestPureThroughputShedRequiresAllRejectionsBelowFloor(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	// Shed disarmed → never a pure throughput shed, regardless of counts.
	if srv.pureThroughputShed(3, 3) {
		t.Fatalf("shed disarmed must never report a pure throughput shed")
	}

	reg.SetDecodeFloorShed(10, true) // arm
	cases := []struct {
		decodeFloor, capacity int
		want                  bool
		why                   string
	}{
		{3, 3, true, "all rejections are throughput sheds → shed"},
		{1, 3, false, "mixed (some fast-but-full) → still queue"},
		{0, 3, false, "no throughput sheds → still queue"},
		{0, 0, false, "no rejections at all → not a shed"},
	}
	for _, c := range cases {
		if got := srv.pureThroughputShed(c.decodeFloor, c.capacity); got != c.want {
			t.Errorf("pureThroughputShed(decodeFloor=%d, capacity=%d) = %v, want %v (%s)",
				c.decodeFloor, c.capacity, got, c.want, c.why)
		}
	}
}

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
	// A decode-floor (throughput) shed is surfaced with a DISTINCT message from an
	// ordinary capacity 429 ("at capacity"), so it is observable as its own class
	// — both to the client and, via the matching reason_code "decode_floor_shed",
	// in the rejection ledger.
	if !strings.Contains(body, "below the decode-speed floor") {
		t.Fatalf("body = %s, want the distinct decode-floor-shed message", body)
	}
}

// Finding-1 regression at the HTTP boundary: with decode-floor hard-shed ARMED,
// a fast-but-budget-FULL fleet (a concurrency/memory capacity rejection, NOT a
// throughput shed) must still QUEUE under queue-before-shed — not fast-429. The
// pre-fix code bypassed the queue whenever DecodeFloorShedArmed() was true,
// regardless of WHY the fleet was full, which regressed queue-before-shed for
// healthy-but-momentarily-full fleets.
func TestDecodeFloorShedArmedStillQueuesMemoryFullFastFleet(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	reg.SetDecodeFloorShed(15, true) // shed ARMED

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	model := "gemma-fast-full-http"
	conn := connectSlowDecodeProvider(t, ctx, ts.URL, model, 40)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	// Budget exhausted (31.5K of 32K, a 256-max request won't fit ⇒
	// freeMemoryAdmits fails ⇒ capacity rejection) but observed decode 40 tok/s
	// ⇒ NOT a decode-floor shed. So decodeFloorRejections (0) < capacityRejections
	// (1): the consumer must queue, not fast-429.
	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			MaxConcurrency:        8,
			ActiveTokenBudgetUsed: 31_500,
			ActiveTokenBudgetMax:  32_768,
			ObservedDecodeTPS:     40,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil &&
			p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 31_500
	})

	reqCtx, reqCancel := context.WithCancel(ctx)
	defer reqCancel()
	done := make(chan int, 1)
	go func() {
		status, _, _ := adaptiveChatRequest(reqCtx, ts.URL, model, 256)
		done <- status
	}()
	// A fast-but-full fleet must NOT be fast-429'd by the throughput-shed path;
	// it should queue (the matching not-shed behaviour as the disabled case).
	select {
	case status := <-done:
		if status == http.StatusTooManyRequests {
			t.Fatalf("got fast 429 for a fast-but-memory-full fleet with shed armed; want queue (queue-before-shed regression)")
		}
	case <-time.After(750 * time.Millisecond):
		// Still in flight (queued) — the expected non-shed path.
	}
	reqCancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
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
