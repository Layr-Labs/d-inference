package api

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// TestAdminRejectModelsQueuedHTTPRequestsReturnModelShed exercises both HTTP
// queue consumers end to end. A request already waiting when the operator PUT
// lands must return promptly as model_shed, never masquerade as queue_full or a
// 120-second queue_timeout.
func TestAdminRejectModelsQueuedHTTPRequestsReturnModelShed(t *testing.T) {
	for _, tc := range []struct {
		name string
		path string
		body func(string) string
	}{
		{
			name: "chat_completions",
			path: "/v1/chat/completions",
			body: func(model string) string {
				return `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":64}`
			},
		},
		{
			name: "legacy_completions",
			path: "/v1/completions",
			body: func(model string) string {
				return `{"model":"` + model + `","prompt":"hello","stream":false,"max_tokens":64}`
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ts, srv := setupAdminRejectModels(t)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			model := "queued-http-shed-" + tc.name
			conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
				{ID: model, ModelType: "chat", Quantization: "4bit"},
			}, testPublicKeyB64())
			defer conn.Close(websocket.StatusNormalClosure, "done")
			p := markOnlyProviderRoutable(t, srv.registry)
			p.Mu().Lock()
			p.BackendCapacity = &protocol.BackendCapacity{
				TotalMemoryGB: 64,
				MaxModelSlots: 3,
				Slots: []protocol.BackendSlotCapacity{{
					Model:          model,
					State:          "running",
					NumRunning:     1,
					MaxConcurrency: 1,
				}},
			}
			p.Mu().Unlock()

			type result struct {
				status     int
				body       string
				retryAfter string
				err        error
			}
			resultCh := make(chan result, 1)
			go func() {
				req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+tc.path, strings.NewReader(tc.body(model)))
				if err != nil {
					resultCh <- result{err: err}
					return
				}
				req.Header.Set("Authorization", "Bearer test-key")
				req.Header.Set("Content-Type", "application/json")
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					resultCh <- result{err: err}
					return
				}
				defer resp.Body.Close()
				data, _ := io.ReadAll(resp.Body)
				resultCh <- result{status: resp.StatusCode, body: string(data), retryAfter: resp.Header.Get("Retry-After")}
			}()

			deadline := time.Now().Add(3 * time.Second)
			for srv.registry.Queue().QueueSize(model) != 1 && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if got := srv.registry.Queue().QueueSize(model); got != 1 {
				t.Fatalf("request never reached queue; depth = %d", got)
			}

			status, body := rejectModelsCall(t, ts, http.MethodPut, "admin-secret", `{"models":["`+model+`"]}`)
			if status != http.StatusOK {
				t.Fatalf("PUT status = %d, want 200; body = %s", status, body)
			}

			select {
			case got := <-resultCh:
				if got.err != nil {
					t.Fatalf("inference request: %v", got.err)
				}
				if got.status != http.StatusTooManyRequests {
					t.Fatalf("status = %d, want 429; body = %s", got.status, got.body)
				}
				if !strings.Contains(got.body, "temporarily rate-limited") || strings.Contains(got.body, "queue timeout") {
					t.Fatalf("body = %s, want model_shed response and no queue_timeout", got.body)
				}
				if got.retryAfter == "" {
					t.Fatal("model_shed 429 missing Retry-After")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("queued request did not fail promptly after reject-models PUT")
			}
		})
	}
}
