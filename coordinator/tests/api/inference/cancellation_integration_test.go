package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// providerCancelLog records every Cancel frame a fake provider receives.
type providerCancelLog struct {
	mu      sync.Mutex
	cancels []time.Time
	first   chan struct{}
}

func (l *providerCancelLog) add(at time.Time) {
	l.mu.Lock()
	l.cancels = append(l.cancels, at)
	if len(l.cancels) == 1 && l.first != nil {
		close(l.first)
	}
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
func attachTestDD(t *testing.T, srv *serverFixture) (*udpCollector, *datadogFlusher) {
	t.Helper()
	collector := newUDPCollector(t)
	dd := newTestDD(t, collector)
	srv.observation.SetDatadog(dd)
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
	if got := findMetrics(packets, cancellation.MetricCancelSent); len(got) != 0 {
		t.Fatalf("cancel_sent must not fire for a clean completion: %v", got)
	}
	if got := findMetrics(packets, cancellation.MetricCancelToTerminalMs); len(got) != 0 {
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
	if got := findMetrics(dd.packets(collector), cancellation.MetricCancelSent); len(got) != 0 {
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

	cancels := &providerCancelLog{first: make(chan struct{})}
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
	// Exercise the resend schedule, not the separate stray-first/abandon race.
	// A chunk before the initial cancel may legitimately trigger two sends.
	select {
	case <-cancels.first:
	case <-ctx.Done():
		t.Fatal("provider did not receive the initial cancel")
	}
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
			TerminalCause: failure.TerminalCauseCancelled,
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

	hist := requireMetricWithTags(t, packets, cancellation.MetricCancelToTerminalMs,
		"terminal:complete", "model:"+model, "cause:"+cancellation.CauseClientGonePost)
	if v := metricValue(t, hist[0]); v < 0.8*float64(zombieFor/time.Millisecond) {
		t.Fatalf("cancel_to_terminal_ms = %v, want >= ~%v (the zombie phase)", v, zombieFor)
	}
	requireMetricWithTags(t, packets, cancellation.MetricCancelSent, "cause:"+cancellation.CauseClientGonePost, "model:"+model)
	requireMetricWithTags(t, packets, cancellation.MetricZombieStreamCancel, "resend_index:1")
	requireMetricWithTags(t, packets, cancellation.MetricZombieStreamCancel, "resend_index:2")
	requireMetricWithTags(t, packets, cancellation.MetricCancelledTerminal, "outcome:"+cancellation.OutcomeCompletePartial, "delivered:true")
	if got := findMetrics(packets, cancellation.MetricCancelUnresolved); len(got) != 0 {
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
	hist := requireMetricWithTags(t, packets, cancellation.MetricCancelToTerminalMs,
		"terminal:error", "model:"+model, "cause:"+cancellation.CauseClientGonePost)
	if v := metricValue(t, hist[0]); v < 0.8*float64(zombieFor/time.Millisecond) {
		t.Fatalf("cancel_to_terminal_ms = %v, want >= ~%v", v, zombieFor)
	}
	requireMetricWithTags(t, packets, cancellation.MetricCancelledTerminal, "outcome:"+cancellation.OutcomeErrorCancelled, "delivered:true")
	requireMetricWithTags(t, packets, cancellation.MetricZombieStreamCancel, "resend_index:1")
	requireNoIdentityInPackets(t, packets, requestID)
}
