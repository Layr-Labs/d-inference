package api

// HTTP-path regression for the drain-time pure-TTFT failure (Codex P2, PR
// #512). A dedicated-model request queues while the dedicated box is at
// capacity; the box then frees its token budget but reports a crawling
// measured prefill rate, so the drain's ReserveProviderEx fails ONLY the
// hard-reject TTFT ceiling. The waiter must get a prompt 429 + Retry-After —
// well under the queue maxWait — instead of hanging for the full wait and
// surfacing a queue timeout.
//
// NOTE: the response BODY is written where WaitForProviderContext's error is
// handled (api/dispatch.go), which is owned by another workstream; until that
// waiter distinguishes registry.ErrQueueTTFTTooSlow the body is the generic
// queue 429. This test pins the latency/status/Retry-After contract that the
// registry-side fix guarantees on its own.

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestQueuedDedicatedRequestFailsFastOnDrainTTFTReject(t *testing.T) {
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetTTFTHardReject(true)
	srv.challengeInterval = time.Hour
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	reg.SetDedicatedModels([]string{"gemma-4"})
	const queueMaxWait = 10 * time.Second
	reg.SetQueue(registry.NewRequestQueue(5, queueMaxWait))

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	gemma := "gemma-4-26b-test"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: gemma, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	// Phase 1: saturated token budget — the preflight capacity-spills and the
	// dispatch path queues the request.
	writeAdaptiveHeartbeat(t, ctx, conn, gemma, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 gemma,
			State:                 "running",
			MaxConcurrency:        8,
			ActiveTokenBudgetUsed: 950,
			ActiveTokenBudgetMax:  1_000,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil && p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 950
	})

	type result struct {
		status     int
		body       string
		retryAfter string
	}
	done := make(chan result, 1)
	go func() {
		status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, gemma)
		if err != nil {
			done <- result{0, err.Error(), ""}
			return
		}
		done <- result{status, body, retryAfter}
	}()

	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		depth, _ := reg.Queue().QueueStats(gemma)
		return depth >= 1
	})
	select {
	case res := <-done:
		t.Fatalf("request returned %d early while it should be queued; body = %s", res.status, res.body)
	default:
	}

	// Phase 2: capacity frees, but the measured prefill rate collapses — the
	// drain reservation now fails PURELY on the TTFT ceiling.
	drainAt := time.Now()
	writeAdaptiveHeartbeat(t, ctx, conn, gemma, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                gemma,
			State:                "running",
			MaxConcurrency:       8,
			ActiveTokenBudgetMax: 32_768,
			ObservedPrefillTPS:   0.05,
		}},
	})

	select {
	case res := <-done:
		elapsed := time.Since(drainAt)
		if res.status != http.StatusTooManyRequests {
			t.Fatalf("status = %d, want 429; body = %s", res.status, res.body)
		}
		if res.retryAfter == "" {
			t.Fatal("drain-time TTFT 429 missing Retry-After header")
		}
		if !strings.Contains(res.body, "TTFT target") || strings.Contains(res.body, "queue timeout") {
			t.Fatalf("body is not the ttft_too_slow response: %s", res.body)
		}
		if elapsed > 3*time.Second {
			t.Fatalf("waiter resolved %v after the drain heartbeat, want a prompt failure", elapsed)
		}
	case <-time.After(queueMaxWait / 2):
		t.Fatalf("queued request still hanging %v after the pure-TTFT drain — the waiter was not failed fast", queueMaxWait/2)
	}
	if depth, _ := reg.Queue().QueueStats(gemma); depth != 0 {
		t.Fatalf("queue depth = %d after the terminal TTFT failure, want 0", depth)
	}
}
