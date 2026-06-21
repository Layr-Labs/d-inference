package api

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// TestPoolExhaustedReturns429NoSpillover exercises the real HTTP path: with
// model-pool isolation enabled (DAR-345), a request for a model whose pool has
// no assigned-and-serving machine — even though a machine in the fleet has that
// model on disk (assigned to a DIFFERENT model) — must get an uptime-neutral 429
// rather than spilling onto the other pool's machine.
func TestPoolExhaustedReturns429NoSpillover(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()
	t.Setenv(envColdDispatch, "false")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	const modelA, modelB = "pool-gptoss", "pool-gemma"
	// One provider with BOTH models on disk (the "flexible" machine).
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: modelA, ModelType: "chat", Quantization: "4bit"},
		{ID: modelB, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, modelA, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model: modelA, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 100_000,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil
	})

	// Enable isolation and bind the only machine to pool A (serving).
	reg.SetAssignmentGateEnabled(true)
	epoch, _, err := reg.AssignProviderModel(p.ID, modelA)
	if err != nil {
		t.Fatalf("assign: %v", err)
	}
	reg.ApplyAssignModelStatus(p.ID, modelA, epoch, protocol.AssignModelStatusSucceeded)

	// A request for model B: its pool is empty (the only machine is in pool A),
	// but B is catalog-capable on that machine. Must be a clean 429 with
	// Retry-After — NOT a spill onto the model-A machine, and NOT a 503.
	status, body, err := adaptiveChatRequest(ctx, ts.URL, modelB, 64)
	if err != nil {
		t.Fatalf("request error: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("model B status=%d body=%s, want 429 (pool_exhausted, no spillover)", status, body)
	}

	// Sanity: the registry verdict agrees the pool is exhausted and the fleet is
	// catalog-capable (could-have-served), so the 429 is uptime-neutral.
	exhausted, capable := reg.PoolExhausted(modelB)
	if !exhausted || capable < 1 {
		t.Fatalf("PoolExhausted(modelB)=%v,%d want true,>=1", exhausted, capable)
	}

	// With the kill switch off, the same request is no longer pool-shed (the
	// isolation is fully reversible).
	reg.SetAssignmentGateEnabled(false)
	if ex, _ := reg.PoolExhausted(modelB); ex {
		t.Fatal("disabling the gate must drop pool_exhausted")
	}
}
