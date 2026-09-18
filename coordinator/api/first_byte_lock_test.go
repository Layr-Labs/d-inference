package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// TestFirstByteReachesClientWhileRegistryWriteLockHeld: once a provider has
// produced content, the first client byte must not wait on the registry
// write lock. The test takes the lock after the provider has received the
// inference request (post-commit) and holds it while the provider streams
// its first chunk; the chunk has to reach the HTTP client while the lock is
// still held. Before the change the capacity-accept recorder in
// commitFirstContent (r.mu.Lock) and the latency sample (r.mu.RLock) both sat
// between the provider chunk and the client write.
func TestFirstByteReachesClientWhileRegistryWriteLockHeld(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	const model = "first-byte-lock-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	gotRequest := make(chan protocol.InferenceRequestMessage, 1)
	sendChunkNow := make(chan struct{})
	sendCompleteNow := make(chan struct{})
	providerErr := make(chan error, 1)
	go func() {
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				providerErr <- err
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(data, &env)
			switch env.Type {
			case protocol.TypeAttestationChallenge:
				_ = conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey))
				continue
			case protocol.TypeInferenceRequest:
				_ = json.Unmarshal(data, &inferReq)
			default:
				continue
			}
			break
		}
		gotRequest <- inferReq
		<-sendChunkNow
		writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"}}]}`+"\n\n")
		<-sendCompleteNow
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1})
		// Drain whatever follows (cancel, challenges) until the socket closes.
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	}()

	type result struct {
		resp *http.Response
		err  error
	}
	responses := make(chan result, 1)
	go func() {
		body := `{"model":"` + model + `","messages":[{"role":"user","content":"hi"}],"stream":true}`
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer test-key")
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		responses <- result{resp, err}
	}()

	select {
	case <-gotRequest:
	case err := <-providerErr:
		t.Fatalf("provider read: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("provider never received the inference request")
	}

	// The reservation is committed (the provider holds the request). Now hold
	// the registry write lock for the whole first-chunk exchange.
	release := reg.HoldWriteLockForTest()
	released := false
	defer func() {
		if !released {
			release()
		}
	}()
	close(sendChunkNow)

	var resp *http.Response
	select {
	case r := <-responses:
		if r.err != nil {
			t.Fatalf("request: %v", r.err)
		}
		resp = r.resp
	case <-time.After(2 * time.Second):
		t.Fatal("response headers did not reach the client within 2 s while the registry write lock was held")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}

	firstBytes := make(chan string, 1)
	go func() {
		buf := make([]byte, 4096)
		n, _ := resp.Body.Read(buf)
		firstBytes <- string(buf[:n])
	}()
	select {
	case first := <-firstBytes:
		if !strings.Contains(first, "Hello") {
			t.Fatalf("first bytes = %q, want the provider's content", first)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("first chunk did not reach the client within 2 s while the registry write lock was held")
	}

	release()
	released = true
	close(sendCompleteNow)

	// The stream still completes normally once the lock is free, including
	// the deferred capacity-accept bookkeeping.
	deadline := time.Now().Add(5 * time.Second)
	buf := make([]byte, 4096)
	var rest strings.Builder
	for time.Now().Before(deadline) {
		n, err := resp.Body.Read(buf)
		rest.Write(buf[:n])
		if err != nil {
			break
		}
		if strings.Contains(rest.String(), "[DONE]") {
			break
		}
	}
	if !strings.Contains(rest.String(), "[DONE]") {
		t.Fatalf("stream did not finish after the lock was released: %q", rest.String())
	}

	// Exactly-once for the capacity-503 rate window through the real path:
	// the asynchronous commit-time accept lands once, and the completion-time
	// re-offer (noteInferenceSuccess) adds nothing because the request was
	// stamped before the goroutine ran. A reject makes the window observable:
	// one accept + one reject = 2 samples, never 3.
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("providers = %d, want 1", len(ids))
	}
	reg.RecordCapacityReject(ids[0], model)
	deadline = time.Now().Add(3 * time.Second)
	for {
		if _, samples := reg.CapacityRejectRate(ids[0], model); samples == 2 {
			break
		}
		if time.Now().After(deadline) {
			_, samples := reg.CapacityRejectRate(ids[0], model)
			t.Fatalf("capacity-rate samples = %d after one streamed request and one reject, want 2 (the async accept never landed or landed twice)", samples)
		}
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	if rate, samples := reg.CapacityRejectRate(ids[0], model); samples != 2 || rate != 0.5 {
		t.Fatalf("capacity-rate = %.2f over %d samples, want 0.5 over 2 (accept counted exactly once)", rate, samples)
	}
}
