package inference_test

import (
	"context"
	"io"
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
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

// queuedFleetHarness boots a coordinator with one REAL WebSocket provider whose
// heartbeat reports a saturated token budget, so every request for model
// capacity-spills to the coordinator queue (queue-before-shed on, cold dispatch
// off). Returns the server, store, registry and test server.
func queuedFleetHarness(t *testing.T, ctx context.Context, cfg TestServerConfig, model string) (*serverFixture, *memory.MemoryStore, *registry.Registry, *httptest.Server) {
	t.Helper()
	return queuedFleetHarnessConfigured(t, ctx, cfg, model, nil)
}

// queuedFleetHarnessConfigured is queuedFleetHarness with a hook that runs on
// the server BEFORE the HTTP listener starts and any provider connects. Wiring
// that provider goroutines read (the Datadog client, emitters) must go through
// it: setting those fields after connectProvider races the heartbeat path.
func queuedFleetHarnessConfigured(t *testing.T, ctx context.Context, cfg TestServerConfig, model string, configure func(*serverFixture)) (*serverFixture, *memory.MemoryStore, *registry.Registry, *httptest.Server) {
	t.Helper()
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	if cfg.FirstContentSLAAccounts == nil {
		cfg.FirstContentSLAAccounts = []string{testConsumerID}
	}
	srv := newComposedServer(reg, st, cfg, logger)
	srv.server.SetChallengeInterval(time.Hour)
	if configure != nil {
		configure(srv)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: model, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "done") })
	p := markOnlyProviderRoutable(t, reg)
	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			MaxConcurrency:        1,
			ActiveTokenBudgetUsed: 950,
			ActiveTokenBudgetMax:  1_000,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil && p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 950
	})
	return srv, st, reg, ts
}

type chatResult struct {
	status     int
	body       string
	retryAfter string
	err        error
}

func chatRequestWithID(ctx context.Context, baseURL, model, requestID string, route ...string) chatResult {
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":64}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		return chatResult{err: err}
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	if len(route) > 0 {
		req.Header.Set("X-Darkbloom-Route", route[0])
	}
	if requestID != "" {
		req.Header.Set("X-Request-ID", requestID)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return chatResult{err: err}
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return chatResult{status: resp.StatusCode, body: string(data), retryAfter: resp.Header.Get("Retry-After")}
}
