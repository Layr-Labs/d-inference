package api

// Public dedicated-model requests must shed promptly when the only slot is
// saturated and no credible release time is known. The configured queue maximum
// must not become a target wait. Registry queue tests separately retain direct
// coverage of a queued waiter's later TTFT rejection.

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

func TestDedicatedRequestRejectsUnforecastableCapacityWait(t *testing.T) {
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{FirstContentSLAAccounts: []string{testConsumerID}}, logger)
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

	start := time.Now()
	status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, gemma)
	if err != nil || status != http.StatusTooManyRequests {
		t.Fatalf("capacity rejection status=%d err=%v body=%s", status, err, body)
	}
	if retryAfter == "" || !strings.Contains(body, "at capacity") || strings.Contains(body, "queue timeout") {
		t.Fatalf("capacity rejection lost immediate retry semantics: retry=%q body=%s", retryAfter, body)
	}
	if elapsed := time.Since(start); elapsed >= queueMaxWait/2 {
		t.Fatalf("unforecastable queue wait consumed %v", elapsed)
	}
	if depth, _ := reg.Queue().QueueStats(gemma); depth != 0 {
		t.Fatalf("queue depth=%d, want no public waiter without release evidence", depth)
	}
}
