package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestIntegration_RequestCancellationOnConsumerDisconnect verifies that when a
// consumer disconnects mid-stream, the coordinator sends a Cancel message to
// the provider so it stops generating tokens.
func TestIntegration_RequestCancellationOnConsumerDisconnect(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "cancel-test-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle the first attestation challenge so the provider becomes routable.
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()

	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	// Provider goroutine: reads the inference request, sends one chunk,
	// then waits for the Cancel message from the coordinator.
	type cancelResult struct {
		receivedCancel bool
		cancelMsg      protocol.CancelMessage
		err            error
	}
	resultCh := make(chan cancelResult, 1)

	go func() {
		// Read messages until we get the inference request.
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				resultCh <- cancelResult{err: err}
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			// Handle additional challenges that may arrive.
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"}}]}`+"\n\n")
				break
			}
		}

		// Now wait for the Cancel message (coordinator sends it when consumer disconnects).
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				resultCh <- cancelResult{err: err}
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			// Handle challenges that may arrive while we wait.
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeCancel {
				var cancelMsg protocol.CancelMessage
				json.Unmarshal(data, &cancelMsg)
				resultCh <- cancelResult{
					receivedCancel: true,
					cancelMsg:      cancelMsg,
				}
				return
			}
		}
	}()

	// Consumer: send a streaming request.
	chatBody := `{"model":"cancel-test-model","messages":[{"role":"user","content":"tell me a story"}],"stream":true}`
	reqCtx, reqCancel := context.WithCancel(ctx)
	httpReq, _ := http.NewRequestWithContext(reqCtx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}

	// Read a small amount to confirm we got the first chunk.
	buf := make([]byte, 4096)
	n, _ := resp.Body.Read(buf)
	firstData := string(buf[:n])
	if !strings.Contains(firstData, "Hello") {
		t.Fatalf("expected first chunk to contain 'Hello', got: %s", firstData)
	}

	// Close the consumer connection by cancelling the request context.
	reqCancel()
	resp.Body.Close()

	// Wait for the provider to receive the cancel message.
	select {
	case result := <-resultCh:
		if result.err != nil {
			t.Fatalf("provider goroutine error: %v", result.err)
		}
		if !result.receivedCancel {
			t.Fatal("provider did not receive a Cancel message")
		}
		if result.cancelMsg.Type != protocol.TypeCancel {
			t.Errorf("cancel message type = %q, want %q", result.cancelMsg.Type, protocol.TypeCancel)
		}
		// The request ID should be non-empty.
		if result.cancelMsg.RequestID == "" {
			t.Error("cancel message request_id is empty")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for provider to receive Cancel message")
	}
}

// TestIntegration_RequestCancellationCleanup verifies that after a consumer
// disconnects mid-stream, the coordinator cleans up the provider's pending
// requests and returns the provider to an idle/online state.
func TestIntegration_RequestCancellationCleanup(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "cancel-cleanup-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle the first attestation challenge.
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()

	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	// Capture the provider ID for later checks.
	providerIDs := reg.ProviderIDs()
	if len(providerIDs) == 0 {
		t.Fatal("no providers registered")
	}
	providerID := providerIDs[0]

	// Provider goroutine: receives inference request, sends one chunk,
	// then waits for the cancel. Does NOT send complete.
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
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"partial"}}]}`+"\n\n")
				continue
			}

			if env.Type == protocol.TypeCancel {
				// Cancel received, we're done.
				return
			}
		}
	}()

	// Consumer: send a streaming request, read the first chunk, then disconnect.
	chatBody := `{"model":"cancel-cleanup-model","messages":[{"role":"user","content":"hello"}],"stream":true}`
	reqCtx, reqCancel := context.WithCancel(ctx)
	httpReq, _ := http.NewRequestWithContext(reqCtx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}

	// Read a bit to confirm streaming started.
	buf := make([]byte, 4096)
	resp.Body.Read(buf)

	// Cancel the consumer request.
	reqCancel()
	resp.Body.Close()

	// Wait for the provider goroutine to finish (it exits upon receiving cancel).
	select {
	case <-providerDone:
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for provider goroutine to finish")
	}

	// Give the coordinator a moment to process the cleanup.
	time.Sleep(300 * time.Millisecond)

	// Verify cleanup: pending request count should be 0.
	p := reg.GetProvider(providerID)
	if p == nil {
		t.Fatal("provider should still be registered after consumer disconnect")
	}

	pendingCount := p.PendingCount()
	if pendingCount != 0 {
		t.Errorf("provider pending count = %d, want 0", pendingCount)
	}

	// Provider status should go back to online (idle), not stuck in serving.
	p.Mu().Lock()
	status := p.Status
	p.Mu().Unlock()
	if status != registry.StatusOnline {
		t.Errorf("provider status = %v, want %v (online/idle)", status, registry.StatusOnline)
	}
}

// TestIntegration_ProviderDeduplicationBySerial verifies that when a second
// provider connects with the same serial number as an existing provider,
// the first provider's connection is closed and only the new provider remains.
func TestIntegration_ProviderDeduplicationBySerial(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serial := "ABC123"
	model := "dedup-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	pubKeyA := testPublicKeyB64()
	pubKeyB := testPublicKeyB64()

	// --- Provider A: connect with serial ABC123 ---
	attestA := createTestAttestationJSONWithSerial(t, serial, pubKeyA)
	connA := connectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyA, attestA)

	// Wait for attestation verification to process (including dedup check).
	time.Sleep(300 * time.Millisecond)

	// Handle the first challenge for provider A.
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, connA, pubKeyA)
	challengeCancel()
	time.Sleep(200 * time.Millisecond)

	// Set trust level for provider A.
	makeProviderRoutable(reg)

	// Verify provider A is routable.
	pA := findRoutableProvider(reg, model)
	if pA == nil {
		t.Fatal("provider A should be routable after registration + challenge")
	}
	providerAID := pA.ID

	// Verify exactly 1 provider.
	if count := reg.ProviderCount(); count != 1 {
		t.Fatalf("provider count = %d, want 1 after provider A registration", count)
	}

	// --- Provider B: connect with the SAME serial ABC123 ---
	attestB := createTestAttestationJSONWithSerial(t, serial, pubKeyB)
	connB := connectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyB, attestB)
	defer connB.Close(websocket.StatusNormalClosure, "")

	// Wait for attestation verification and deduplication to complete.
	time.Sleep(500 * time.Millisecond)

	// Verify provider A was evicted (only 1 provider should remain).
	if count := reg.ProviderCount(); count != 1 {
		t.Fatalf("provider count = %d, want 1 after deduplication", count)
	}

	// The remaining provider should be provider B (not A).
	pOld := reg.GetProvider(providerAID)
	if pOld != nil {
		t.Error("provider A should have been evicted from registry")
	}

	// Provider A's WebSocket should be closed. Keep reading until we get an
	// error (there may be pending challenge messages in the buffer before the
	// close frame arrives).
	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	connAClosed := false
	for {
		_, _, readErr := connA.Read(readCtx)
		if readErr != nil {
			connAClosed = true
			break
		}
	}
	if !connAClosed {
		t.Error("provider A's WebSocket should be closed after deduplication")
	}

	// Handle the challenge for provider B so it becomes routable.
	challengeCtx2, challengeCancel2 := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx2, connB, pubKeyB)
	challengeCancel2()
	time.Sleep(200 * time.Millisecond)

	makeProviderRoutable(reg)

	// Verify provider B is routable.
	pB := findRoutableProvider(reg, model)
	if pB == nil {
		t.Fatal("provider B should be routable after deduplication + challenge")
	}
}

// TestIntegration_ProviderDeduplicationPreservesNewest verifies that after
// provider B replaces provider A (same serial), inference requests go to
// provider B and provider A's WebSocket is closed.
func TestIntegration_ProviderDeduplicationPreservesNewest(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serial := "DEDUP-NEWEST-001"
	model := "dedup-newest-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	pubKeyA := testPublicKeyB64()
	pubKeyB := testPublicKeyB64()

	// --- Provider A: connect with serial ---
	attestA := createTestAttestationJSONWithSerial(t, serial, pubKeyA)
	connA := connectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyA, attestA)

	time.Sleep(300 * time.Millisecond)

	// Handle challenge for A.
	challengeCtxA, challengeCancelA := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtxA, connA, pubKeyA)
	challengeCancelA()
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	// --- Provider B: connect with same serial, replacing A ---
	attestB := createTestAttestationJSONWithSerial(t, serial, pubKeyB)
	connB := connectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyB, attestB)
	defer connB.Close(websocket.StatusNormalClosure, "")

	// Wait for deduplication.
	time.Sleep(500 * time.Millisecond)

	// Verify A was evicted.
	if count := reg.ProviderCount(); count != 1 {
		t.Fatalf("provider count = %d, want 1 after dedup", count)
	}

	// Verify A's WebSocket is actually closed. Drain any buffered messages
	// until we get a read error.
	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	connAClosed := false
	for {
		_, _, readErr := connA.Read(readCtx)
		if readErr != nil {
			connAClosed = true
			break
		}
	}
	if !connAClosed {
		t.Error("provider A's WebSocket should be closed after being replaced")
	}

	// Handle challenge for B so it becomes routable.
	challengeCtxB, challengeCancelB := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtxB, connB, pubKeyB)
	challengeCancelB()
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	// Provider B should be the one serving requests. Send a request and
	// verify provider B receives and serves it.
	providerBDone := make(chan struct{})
	var providerBReceivedRequest bool
	var mu sync.Mutex

	go func() {
		defer close(providerBDone)
		for {
			_, data, err := connB.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKeyB)
				connB.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				mu.Lock()
				providerBReceivedRequest = true
				mu.Unlock()

				writeEncryptedTestChunk(t, ctx, connB, inferReq, pubKeyB,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"from-B"}}]}`+"\n\n")

				complete := protocol.InferenceCompleteMessage{
					Type:      protocol.TypeInferenceComplete,
					RequestID: inferReq.RequestID,
					Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
				}
				completeData, _ := json.Marshal(complete)
				connB.Write(ctx, websocket.MessageText, completeData)
				return
			}
		}
	}()

	// Send a consumer request.
	chatBody := `{"model":"dedup-newest-model","messages":[{"role":"user","content":"hello"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}

	// Read the response body.
	body, _ := io.ReadAll(resp.Body)
	responseStr := string(body)

	if !strings.Contains(responseStr, "from-B") {
		t.Errorf("response should contain 'from-B' (served by provider B), got: %s", responseStr)
	}

	// Wait for provider B goroutine to finish.
	select {
	case <-providerBDone:
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for provider B goroutine")
	}

	mu.Lock()
	gotRequest := providerBReceivedRequest
	mu.Unlock()

	if !gotRequest {
		t.Error("provider B should have received the inference request")
	}
}

// ---------------------------------------------------------------------------

// providerCancelLog records every Cancel frame a fake provider receives.
type providerCancelLog struct {
	mu      sync.Mutex
	cancels []time.Time
}

func (l *providerCancelLog) add(at time.Time) {
	l.mu.Lock()
	l.cancels = append(l.cancels, at)
	l.mu.Unlock()
}

func (l *providerCancelLog) times() []time.Time {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]time.Time(nil), l.cancels...)
}

// runFakeProviderReader drives a fake provider's read loop: answers
// attestation challenges, records Cancel frames, and hands each inference
// request to onRequest (which runs on the reader goroutine). The returned
// channel closes when the socket is closed.
func runFakeProviderReader(
	ctx context.Context,
	conn *websocket.Conn,
	pubKey string,
	cancels *providerCancelLog,
	onRequest func(protocol.InferenceRequestMessage),
) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(data, &env)
			switch env.Type {
			case protocol.TypeAttestationChallenge:
				_ = conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey))
			case protocol.TypeInferenceRequest:
				var inferReq protocol.InferenceRequestMessage
				_ = json.Unmarshal(data, &inferReq)
				onRequest(inferReq)
			case protocol.TypeCancel:
				cancels.add(time.Now())
			}
		}
	}()
	return done
}

func writeProviderFrame(ctx context.Context, conn *websocket.Conn, msg any) {
	data, _ := json.Marshal(msg)
	_ = conn.Write(ctx, websocket.MessageText, data)
}

func cancelTestChunkSSE(text string) string {
	return `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"` + text + `"}}]}` + "\n\n"
}

// attachTestDD wires a real DogStatsD client (UDP collector) into srv.
func attachTestDD(t *testing.T, srv *Server) (*udpCollector, *datadogFlusher) {
	t.Helper()
	collector := newUDPCollector(t)
	dd := newTestDD(t, collector)
	srv.SetDatadog(dd)
	t.Cleanup(func() {
		dd.Close()
		collector.Close()
	})
	return collector, &datadogFlusher{flush: func() { _ = dd.Statsd.Flush() }}
}

type datadogFlusher struct{ flush func() }

// packets flushes the client and drains everything the collector received.
func (f *datadogFlusher) packets(c *udpCollector) []string {
	f.flush()
	var out []string
	for range 3 {
		out = append(out, c.drain()...)
	}
	return out
}

// metricValue parses the sample value out of a DogStatsD line
// ("name:VALUE|type|#tags").
func metricValue(t *testing.T, packet string) float64 {
	t.Helper()
	head, _, _ := strings.Cut(packet, "|")
	v, err := strconv.ParseFloat(head[strings.LastIndex(head, ":")+1:], 64)
	if err != nil {
		t.Fatalf("metric value in %q: %v", packet, err)
	}
	return v
}

func requireMetricWithTags(t *testing.T, packets []string, name string, tags ...string) []string {
	t.Helper()
	var matched []string
	for _, p := range findMetrics(packets, name) {
		ok := true
		for _, tag := range tags {
			if !strings.Contains(p, tag) {
				ok = false
				break
			}
		}
		if ok {
			matched = append(matched, p)
		}
	}
	if len(matched) == 0 {
		t.Fatalf("no %s packet carrying %v; packets=%v", name, tags, findMetrics(packets, name))
	}
	return matched
}

// connectRoutableProvider connects a fake provider for model and makes it
// routable (attestation challenge answered, hardware trust).
func connectRoutableProvider(t *testing.T, ctx context.Context, tsURL, model, pubKey string, reg *registry.Registry) *websocket.Conn {
	t.Helper()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	conn := connectProvider(t, ctx, tsURL, models, pubKey)
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)
	return conn
}

func streamingChatRequest(ctx context.Context, tsURL, model string) (*http.Response, error) {
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, tsURL+"/v1/chat/completions", strings.NewReader(body))
	httpReq.Header.Set("Authorization", "Bearer test-key")
	return http.DefaultClient.Do(httpReq)
}

// TestIntegration_NoCancelAfterCleanCompletion: a request that streams and
// completes cleanly must NOT be followed by a Cancel frame. Before this rule
// the post-commit defer cancelled after every committed request — one no-op
// cancel per dispatch fleet-wide.
func TestIntegration_NoCancelAfterCleanCompletion(t *testing.T) {
	srv, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	collector, dd := attachTestDD(t, srv)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pubKey := testPublicKeyB64()
	model := "clean-complete-model"
	conn := connectRoutableProvider(t, ctx, ts.URL, model, pubKey, reg)
	defer conn.Close(websocket.StatusNormalClosure, "")

	cancels := &providerCancelLog{}
	readerDone := runFakeProviderReader(ctx, conn, pubKey, cancels, func(inferReq protocol.InferenceRequestMessage) {
		writeProviderFrame(ctx, conn, testEncryptedChunk(t, inferReq, pubKey, cancelTestChunkSSE("Hello")))
		writeProviderFrame(ctx, conn, protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: inferReq.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
		})
	})

	resp, err := streamingChatRequest(ctx, ts.URL, model)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "Hello") {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}

	// Keep the provider listening well past the completion.
	time.Sleep(time.Second)
	conn.Close(websocket.StatusNormalClosure, "")
	<-readerDone

	if n := len(cancels.times()); n != 0 {
		t.Fatalf("provider received %d Cancel frame(s) after a clean inference_complete, want 0", n)
	}
	packets := dd.packets(collector)
	if got := findMetrics(packets, metricCancelSent); len(got) != 0 {
		t.Fatalf("cancel_sent must not fire for a clean completion: %v", got)
	}
	if got := findMetrics(packets, metricCancelToTerminalMs); len(got) != 0 {
		t.Fatalf("cancel_to_terminal_ms must not fire for a clean completion: %v", got)
	}
}

// TestIntegration_NoCancelAfterProviderErrorTerminal: a provider that fails
// an attempt with inference_error has nothing running, so the retry path must
// not send it a Cancel frame.
func TestIntegration_NoCancelAfterProviderErrorTerminal(t *testing.T) {
	srv, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	collector, dd := attachTestDD(t, srv)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pubKey := testPublicKeyB64()
	model := "provider-error-model"
	conn := connectRoutableProvider(t, ctx, ts.URL, model, pubKey, reg)
	defer conn.Close(websocket.StatusNormalClosure, "")

	cancels := &providerCancelLog{}
	readerDone := runFakeProviderReader(ctx, conn, pubKey, cancels, func(inferReq protocol.InferenceRequestMessage) {
		writeProviderFrame(ctx, conn, protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			RequestID:   inferReq.RequestID,
			Error:       "generation failed",
			StatusCode:  http.StatusInternalServerError,
			FailureCode: protocol.FailureCodeGenerationFailure,
		})
	})

	resp, err := streamingChatRequest(ctx, ts.URL, model)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatalf("status=%d, want a failure after the only provider errored", resp.StatusCode)
	}

	time.Sleep(time.Second)
	conn.Close(websocket.StatusNormalClosure, "")
	<-readerDone

	if n := len(cancels.times()); n != 0 {
		t.Fatalf("provider received %d Cancel frame(s) after its own inference_error, want 0", n)
	}
	if got := findMetrics(dd.packets(collector), metricCancelSent); len(got) != 0 {
		t.Fatalf("cancel_sent must not fire after a provider error terminal: %v", got)
	}
}

// runZombieStreamScenario streams one chunk, disconnects the consumer (which
// sends the first cancel), then keeps streaming chunks from the fake provider
// for zombieFor as if it had not honored the cancel, and finally sends the
// given terminal ("complete" or "error"). It returns the Cancel frame times
// the provider observed, the DogStatsD packets, the model, and the request id.
func runZombieStreamScenario(t *testing.T, terminal string, zombieFor time.Duration) ([]time.Time, []string, string, string) {
	t.Helper()
	srv, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	collector, dd := attachTestDD(t, srv)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pubKey := testPublicKeyB64()
	model := "zombie-" + terminal + "-model"
	conn := connectRoutableProvider(t, ctx, ts.URL, model, pubKey, reg)
	defer conn.Close(websocket.StatusNormalClosure, "")

	cancels := &providerCancelLog{}
	reqCh := make(chan protocol.InferenceRequestMessage, 1)
	readerDone := runFakeProviderReader(ctx, conn, pubKey, cancels, func(inferReq protocol.InferenceRequestMessage) {
		writeProviderFrame(ctx, conn, testEncryptedChunk(t, inferReq, pubKey, cancelTestChunkSSE("Hello")))
		reqCh <- inferReq
	})

	reqCtx, reqCancel := context.WithCancel(ctx)
	resp, err := streamingChatRequest(reqCtx, ts.URL, model)
	if err != nil {
		reqCancel()
		t.Fatalf("http request: %v", err)
	}
	buf := make([]byte, 4096)
	n, _ := resp.Body.Read(buf)
	if !strings.Contains(string(buf[:n]), "Hello") {
		reqCancel()
		t.Fatalf("expected first chunk to contain 'Hello', got: %s", buf[:n])
	}
	// Consumer leaves mid-stream: the coordinator sends the first cancel.
	reqCancel()
	resp.Body.Close()

	inferReq := <-reqCh
	// The provider ignores the cancel and keeps generating.
	deadline := time.Now().Add(zombieFor)
	for i := 0; time.Now().Before(deadline); i++ {
		writeProviderFrame(ctx, conn, testEncryptedChunk(t, inferReq, pubKey, cancelTestChunkSSE(fmt.Sprintf("z%d", i))))
		time.Sleep(100 * time.Millisecond)
	}
	switch terminal {
	case "complete":
		writeProviderFrame(ctx, conn, protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: inferReq.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 20},
		})
	case "error":
		writeProviderFrame(ctx, conn, protocol.InferenceErrorMessage{
			Type:          protocol.TypeInferenceError,
			RequestID:     inferReq.RequestID,
			Error:         "request cancelled",
			StatusCode:    499,
			FailureCode:   protocol.FailureCodeCancelled,
			TerminalCause: terminalCauseCancelled,
		})
	default:
		t.Fatalf("unknown terminal %q", terminal)
	}
	// Let the terminal settle (handleComplete runs off the read loop).
	time.Sleep(300 * time.Millisecond)
	conn.Close(websocket.StatusNormalClosure, "")
	<-readerDone
	return cancels.times(), dd.packets(collector), model, inferReq.RequestID
}

func requireNoIdentityInPackets(t *testing.T, packets []string, requestID string) {
	t.Helper()
	for _, p := range packets {
		if strings.Contains(p, requestID) {
			t.Fatalf("metric must not carry the request id: %q", p)
		}
	}
}

// TestIntegration_ZombieStreamRecancelScheduleAndCompleteTerminal: a provider
// that keeps streaming after the consumer-gone cancel is re-cancelled at
// +1 s and +3 s after the first cancel (escalating schedule), and its late
// inference_complete is correlated with that cancel: cancel_to_terminal_ms
// {terminal:complete, model, cause:client_gone_post} fires with the
// cancel→terminal latency, and the terminal is classified complete_partial
// instead of "unknown".
func TestIntegration_ZombieStreamRecancelScheduleAndCompleteTerminal(t *testing.T) {
	const zombieFor = 3500 * time.Millisecond
	cancels, packets, model, requestID := runZombieStreamScenario(t, "complete", zombieFor)

	if len(cancels) < 3 || len(cancels) > 4 {
		t.Fatalf("Cancel frames over %v of zombie chunks = %d (%v), want 3: first, +1 s, +3 s", zombieFor, len(cancels), cancels)
	}
	gap1, gap2 := cancels[1].Sub(cancels[0]), cancels[2].Sub(cancels[0])
	if gap1 < 900*time.Millisecond || gap1 > 2500*time.Millisecond {
		t.Fatalf("first re-send at +%v after the first cancel, want ~+1 s", gap1)
	}
	if gap2 < 2900*time.Millisecond || gap2 > 6*time.Second {
		t.Fatalf("second re-send at +%v after the first cancel, want ~+3 s", gap2)
	}

	hist := requireMetricWithTags(t, packets, metricCancelToTerminalMs,
		"terminal:complete", "model:"+model, "cause:"+cancelCauseClientGonePost)
	if v := metricValue(t, hist[0]); v < 0.8*float64(zombieFor/time.Millisecond) {
		t.Fatalf("cancel_to_terminal_ms = %v, want >= ~%v (the zombie phase)", v, zombieFor)
	}
	requireMetricWithTags(t, packets, metricCancelSent, "cause:"+cancelCauseClientGonePost, "model:"+model)
	requireMetricWithTags(t, packets, metricZombieStreamCancel, "resend_index:1")
	requireMetricWithTags(t, packets, metricZombieStreamCancel, "resend_index:2")
	requireMetricWithTags(t, packets, metricCancelledTerminal, "outcome:"+cancelledOutcomeCompletePartial)
	if got := findMetrics(packets, metricCancelUnresolved); len(got) != 0 {
		t.Fatalf("a correlated terminal must not also count as unresolved: %v", got)
	}
	requireNoIdentityInPackets(t, packets, requestID)
}

// TestIntegration_CancelToTerminalOnLateErrorTerminal: the provider honors
// the cancel late with a 499 inference_error; the terminal is correlated
// (terminal:error) and classified error_cancelled.
func TestIntegration_CancelToTerminalOnLateErrorTerminal(t *testing.T) {
	const zombieFor = 1200 * time.Millisecond
	cancels, packets, model, requestID := runZombieStreamScenario(t, "error", zombieFor)

	if len(cancels) < 2 || len(cancels) > 3 {
		t.Fatalf("Cancel frames over %v of zombie chunks = %d (%v), want 2: first, +1 s", zombieFor, len(cancels), cancels)
	}
	hist := requireMetricWithTags(t, packets, metricCancelToTerminalMs,
		"terminal:error", "model:"+model, "cause:"+cancelCauseClientGonePost)
	if v := metricValue(t, hist[0]); v < 0.8*float64(zombieFor/time.Millisecond) {
		t.Fatalf("cancel_to_terminal_ms = %v, want >= ~%v", v, zombieFor)
	}
	requireMetricWithTags(t, packets, metricCancelledTerminal, "outcome:"+cancelledOutcomeErrorCancelled)
	requireMetricWithTags(t, packets, metricZombieStreamCancel, "resend_index:1")
	requireNoIdentityInPackets(t, packets, requestID)
}

// TestCancelDispatchEnqueuesCancelBeforeIdleDrain pins the abandon order in
// cancelDispatch: RemovePending, then the cancel frame onto the provider's
// control lane, THEN SetProviderIdle — whose synchronous queue drain can hand
// the freed slot to a waiting request. Before the reorder the drain (one
// reservation scan per queued waiter) ran first and the stop reached the wire
// after it. The drain's assignment send blocks on the unbuffered ResponseCh,
// so the receiver observes the writer's control-lane counters strictly before
// SetProviderIdle returns.
func TestCancelDispatchEnqueuesCancelBeforeIdleDrain(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "k"}), ServerConfig{}, logger)
	serverConn, clientConn := testWebSocketPairAPI(t)
	go func() {
		for {
			if _, _, err := clientConn.Read(context.Background()); err != nil {
				return
			}
		}
	}()
	const model = "cancel-order-model"
	provider := makeRoutableProviderConn(t, reg, "p-order", model, serverConn)
	defer reg.Disconnect(provider.ID)

	pr := &registry.PendingRequest{
		RequestID:  "req-abandoned",
		Model:      model,
		ChunkCh:    make(chan registry.ProviderChunk, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	waiter := &registry.QueuedRequest{
		RequestID:  "req-waiting",
		Model:      model,
		ResponseCh: make(chan *registry.Provider), // unbuffered: the drain blocks until observed
	}
	reg.Queue().Enqueue(waiter)

	type observation struct {
		assigned      *registry.Provider
		controlFrames uint64
	}
	observed := make(chan observation, 1)
	go func() {
		assigned := <-waiter.ResponseCh
		st := provider.LinkStats()
		observed <- observation{assigned, st.ControlFramesOut + uint64(st.ControlQueueDepth)}
	}()

	srv.cancelDispatch(provider, pr, cancelCauseClientGonePre)

	select {
	case got := <-observed:
		if got.assigned == nil || got.assigned.ID != provider.ID {
			t.Fatalf("queued waiter assigned to %v, want the freed provider", got.assigned)
		}
		if got.controlFrames == 0 {
			t.Fatal("the idle drain assigned the freed slot before the cancel frame was on the control lane")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("queued waiter was not drained by SetProviderIdle")
	}
}
