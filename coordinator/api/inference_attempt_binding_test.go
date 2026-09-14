package api

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A response writer can outlive the configuration lookup that constructed it.
// Its real error and completion paths must use the current registry, catalog
// context and metrics client, while retaining their existing classification.
func TestResponseFeedbackUsesCurrentAttemptBindings(t *testing.T) {
	for _, tc := range []struct {
		name                       string
		oldContext, currentContext int
		oldBudget                  int64
		wantGrayBox                bool
	}{
		{"request context", 1000, 50, 1, false},
		{"provider budget", 50, 200, 1000, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			oldStore := store.NewMemory(store.Config{AdminKey: "key"})
			currentStore := store.NewMemory(store.Config{AdminKey: "key"})
			oldRegistry := registry.New(logger)
			currentRegistry := registry.New(logger)
			const model, providerID = "response-feedback-model", "response-feedback-provider"
			registerModelContext(t, oldStore, model, tc.oldContext)
			registerModelContext(t, currentStore, model, tc.currentContext)
			makeRoutableProvider(t, oldRegistry, providerID, model)
			makeRoutableProvider(t, currentRegistry, providerID, model)
			setProviderModelBudget(t, oldRegistry, providerID, model, tc.oldBudget)
			setProviderModelBudget(t, currentRegistry, providerID, model, 100)

			srv := NewServer(oldRegistry, oldStore, ServerConfig{}, logger)
			writer := srv.responseWriter()
			srv.registry, srv.store = currentRegistry, currentStore
			collector := newUDPCollector(t)
			defer collector.Close()
			dd := newTestDD(t, collector)
			defer dd.Close()
			srv.SetDatadog(dd)
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			request := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
			failure := &protocol.InferenceErrorMessage{
				StatusCode: http.StatusServiceUnavailable,
				Error:      "token_budget_exhausted: request exceeds batch token budget",
			}
			for i := 0; i < 5; i++ {
				w := httptest.NewRecorder()
				writer.NonStream(w, request, capacityTestPending(model, providerID, i), nil, failure)
				if w.Code != http.StatusServiceUnavailable {
					t.Fatalf("provider error response = %d, want 503: %s", w.Code, w.Body.String())
				}
			}
			if !currentRegistry.CapacityCooldownActive(providerID, model) {
				t.Fatal("response errors must feed the current registry's capacity cooldown")
			}
			if got := currentRegistry.BudgetClampActive(providerID, model); got != tc.wantGrayBox {
				t.Fatalf("current catalog/budget classification armed clamp=%v, want %v", got, tc.wantGrayBox)
			}
			_, samples := currentRegistry.CapacityRejectRate(providerID, model)
			if tc.wantGrayBox && samples != 5 || !tc.wantGrayBox && samples != 0 {
				t.Fatalf("current capacity rate has %d samples, want gray-box recording=%v", samples, tc.wantGrayBox)
			}
			if oldRegistry.CapacityCooldownActive(providerID, model) || oldRegistry.BudgetClampActive(providerID, model) {
				t.Fatal("response feedback mutated the registry captured before configuration changed")
			}
			_ = dd.Statsd.Flush()
			if got := findMetrics(collector.drain(), "routing.capacity_cooldown_tripped"); len(got) != 1 {
				t.Fatalf("current metrics client must observe one cooldown transition, got %v", got)
			}

			// The same writer's successful completion clears that current cooldown.
			completed := capacityTestPending(model, providerID, 6)
			completed.CompleteCh <- protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1}
			close(completed.ChunkCh)
			w := httptest.NewRecorder()
			writer.NonStream(w, request, completed, []string{`{"object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`}, nil)
			if w.Code != http.StatusOK {
				t.Fatalf("completed response = %d, want 200: %s", w.Code, w.Body.String())
			}
			if currentRegistry.CapacityCooldownActive(providerID, model) {
				t.Fatal("successful response did not clear the current registry's capacity cooldown")
			}
		})
	}
}
