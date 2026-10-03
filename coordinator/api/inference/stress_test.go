package inference

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
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

func TestStress_ProviderCrashDuringMultipleInFlightRequests(t *testing.T) {
	t.Setenv(envQueueBeforeShed, "true")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	// The queue, not the client guard, must terminate the undispatched request.
	reg.SetQueue(registry.NewRequestQueue(50, time.Second))
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	testComposition(srv).SetChallengeInterval(1 * time.Second)

	const inFlight = registry.DefaultMaxConcurrent
	const numRequests = inFlight + 1
	handlerDone := make(chan struct{}, numRequests)
	handler := srv.Handler()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/chat/completions" {
			defer func() { handlerDone <- struct{}{} }()
		}
		handler.ServeHTTP(w, r)
	}))
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "crash-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.CloseNow()

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	p := findRoutableProvider(reg, model)
	if p == nil {
		t.Fatal("provider must be routable before starting requests")
	}

	// Keep every dispatched stream open until both active and queued work exist.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal(data, &env); err != nil {
				t.Errorf("decode provider message: %v", err)
				return
			}

			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
					return
				}
			}
			if env.Type == protocol.TypeInferenceRequest {
				var req protocol.InferenceRequestMessage
				if err := json.Unmarshal(data, &req); err != nil {
					t.Errorf("decode inference request: %v", err)
					return
				}
				writeEncryptedTestChunk(t, ctx, conn, req, pubKey,
					`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"partial..."},"finish_reason":null}]}`+"\n\n")
			}
		}
	}()

	type result struct {
		index  int
		status int
		body   string
		err    error
	}
	results := make(chan result, numRequests)
	streamStarted := make(chan struct{}, inFlight)
	startRequest := func(idx int) {
		go func() {
			got := result{index: idx}
			defer func() { results <- got }()
			body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"req %d"}],"stream":true}`, model, idx)
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
				strings.NewReader(body))
			if err != nil {
				got.err = err
				return
			}
			req.Header.Set("Authorization", "Bearer test-key")

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				got.err = err
				return
			}
			defer resp.Body.Close()
			got.status = resp.StatusCode
			reader := bufio.NewReader(resp.Body)
			if idx < inFlight && resp.StatusCode == http.StatusOK {
				for {
					line, err := reader.ReadString('\n')
					got.body += line
					if err != nil {
						got.err = fmt.Errorf("read partial stream: %w", err)
						return
					}
					if strings.Contains(line, `"content":"partial..."`) {
						streamStarted <- struct{}{}
						break
					}
				}
			}
			remaining, err := io.ReadAll(reader)
			got.body += string(remaining)
			got.err = err
		}()
	}

	for i := range inFlight {
		startRequest(i)
	}
	for range inFlight {
		select {
		case <-streamStarted:
		case got := <-results:
			t.Fatalf("request ended before crash: %+v", got)
		case <-ctx.Done():
			t.Fatal("timed out waiting for partial streams")
		}
	}
	startRequest(inFlight)
	waitFor(t, 5*time.Second, "one queued request behind active streams", func() bool {
		return reg.Queue().QueueSize(model) == 1
	})
	if got := p.PendingCount(); got != inFlight {
		t.Fatalf("pending requests before crash = %d, want %d", got, inFlight)
	}
	if err := conn.CloseNow(); err != nil {
		t.Fatalf("crash provider connection: %v", err)
	}

	for range numRequests {
		select {
		case got := <-results:
			if got.err != nil {
				t.Errorf("request %d transport/body error: %v", got.index, got.err)
				continue
			}
			if got.index < inFlight {
				if got.status != http.StatusOK || !strings.Contains(got.body, `"content":"partial..."`) ||
					strings.Count(got.body, `"type":"provider_error"`) != 1 || strings.Contains(got.body, "data: [DONE]") {
					t.Errorf("active request %d: status=%d body=%s", got.index, got.status, got.body)
				}
			} else if got.status != http.StatusTooManyRequests || !strings.Contains(got.body, "queue timeout") {
				t.Errorf("queued request: status=%d body=%s, want queue-timeout 429", got.status, got.body)
			}
		case <-ctx.Done():
			t.Fatal("client guard expired before server completed all crash outcomes")
		}
	}
	for range numRequests {
		select {
		case <-handlerDone:
		case <-ctx.Done():
			t.Fatal("server-side request handler did not finish")
		}
	}
	select {
	case <-providerDone:
	case <-ctx.Done():
		t.Fatal("provider read loop did not finish")
	}
	waitFor(t, 5*time.Second, "provider removal and pending request cleanup", func() bool {
		return reg.ProviderCount() == 0 && p.PendingCount() == 0
	})
	if got := reg.Queue().QueueSize(model); got != 0 {
		t.Errorf("queue size after handlers completed = %d, want 0", got)
	}
}
