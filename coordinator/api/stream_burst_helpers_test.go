package api

// Shared harness for the streaming-relay burst tests: a fake WebSocket
// provider that answers attestation challenges and, on the inference request,
// runs a scripted burst (chunks, then completion / error / wait-for-cancel),
// plus a consumer that captures the raw SSE byte stream over real HTTP.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

const burstTestModel = "burst-model"

// burstProvider is a scripted fake provider. script runs on the provider's
// read goroutine when the inference request arrives; it may write chunks
// synchronously or spawn its own goroutine. cancelled is closed when the
// coordinator sends a cancel for the request.
type burstProvider struct {
	conn      *websocket.Conn
	pubKey    string
	cancelled chan struct{}
	once      sync.Once
	done      chan struct{}
}

func (p *burstProvider) cancelledOnce() {
	p.once.Do(func() { close(p.cancelled) })
}

// startBurstProvider connects a routable provider serving burstTestModel and
// drives it with script. The returned provider's done channel closes when the
// read loop exits (connection closed).
func startBurstProvider(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry,
	script func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage)) *burstProvider {
	t.Helper()
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: burstTestModel, ModelType: "test", Quantization: "4bit"}}
	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	makeProviderRoutable(reg)
	p := &burstProvider{conn: conn, pubKey: pubKey, cancelled: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(p.done)
		handleProviderMessages(ctx, t, conn, func(msgType string, data []byte) []byte {
			switch msgType {
			case protocol.TypeAttestationChallenge:
				return makeValidChallengeResponse(data, pubKey)
			case protocol.TypeInferenceRequest:
				var req protocol.InferenceRequestMessage
				if err := json.Unmarshal(data, &req); err != nil {
					t.Errorf("unmarshal inference request: %v", err)
					return nil
				}
				script(ctx, p, req)
			case protocol.TypeCancel:
				p.cancelledOnce()
			}
			return nil
		})
	}()
	return p
}

func (p *burstProvider) writeChunk(t *testing.T, ctx context.Context, req protocol.InferenceRequestMessage, sse string) {
	t.Helper()
	writeEncryptedTestChunk(t, ctx, p.conn, req, p.pubKey, sse)
}

func (p *burstProvider) writeComplete(t *testing.T, ctx context.Context, req protocol.InferenceRequestMessage, usage protocol.UsageInfo) {
	t.Helper()
	complete := protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: req.RequestID,
		Usage:     usage,
	}
	data, _ := json.Marshal(complete)
	if err := p.conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Errorf("write complete: %v", err)
	}
}

func (p *burstProvider) writeError(t *testing.T, ctx context.Context, req protocol.InferenceRequestMessage, msg protocol.InferenceErrorMessage) {
	t.Helper()
	msg.Type = protocol.TypeInferenceError
	msg.RequestID = req.RequestID
	data, _ := json.Marshal(msg)
	if err := p.conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Errorf("write error: %v", err)
	}
}

// chatContentChunk is one chat.completion.chunk content delta, framed the way
// the Swift provider frames it (SSE line + blank line).
func chatContentChunk(text string) string {
	return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"` +
		burstTestModel + `","choices":[{"index":0,"delta":{"content":"` + text + `"},"finish_reason":null}]}` + "\n\n"
}

// chatReasoningNullContentChunk exercises normalizeSSEChunk's slow path inside
// a burst: a null content alongside a reasoning delta.
func chatReasoningNullContentChunk(reasoning string) string {
	return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"` +
		burstTestModel + `","choices":[{"index":0,"delta":{"content":null,"reasoning_content":"` + reasoning + `"},"finish_reason":null}],"usage":null}` + "\n\n"
}

func chatFinishChunk(reason string) string {
	return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"` +
		burstTestModel + `","choices":[{"index":0,"delta":{},"finish_reason":"` + reason + `"}]}` + "\n\n"
}

func chatUsageChunk(prompt, completion int) string {
	return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"` +
		burstTestModel + `","choices":[],"usage":{"prompt_tokens":` + strconv.Itoa(prompt) + `,"completion_tokens":` + strconv.Itoa(completion) +
		`,"total_tokens":` + strconv.Itoa(prompt+completion) + `}}` + "\n\n"
}

// burstChatChunks is the canonical 50-content-delta burst plus the terminal
// finish / usage / provider-[DONE] frames used by the golden tests.
func burstChatChunks(n int) []string {
	chunks := make([]string, 0, n+3)
	for i := 0; i < n; i++ {
		if i%17 == 5 {
			chunks = append(chunks, chatReasoningNullContentChunk("think"+strconv.Itoa(i)))
			continue
		}
		chunks = append(chunks, chatContentChunk("t"+strconv.Itoa(i)+" "))
	}
	chunks = append(chunks, chatFinishChunk("stop"))
	chunks = append(chunks, chatUsageChunk(10, n))
	chunks = append(chunks, "data: [DONE]\n\n")
	return chunks
}

// streamRequest posts a streaming request and returns the status and the raw
// SSE body. The body is read to EOF (or ctx cancellation).
func streamRequest(t *testing.T, ctx context.Context, ts *httptest.Server, path, body string) (int, http.Header, []byte) {
	t.Helper()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("stream request: %v", err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, out
}

// sseEvents splits a raw SSE body into non-empty event groups.
func sseEvents(body []byte) []string {
	var events []string
	for _, group := range strings.Split(string(body), "\n\n") {
		if strings.TrimSpace(group) == "" {
			continue
		}
		events = append(events, group)
	}
	return events
}

// waitClosed fails the test if ch is not closed within d.
func waitClosed(t *testing.T, ch <-chan struct{}, d time.Duration, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(d):
		t.Fatalf("timed out waiting for %s", what)
	}
}
