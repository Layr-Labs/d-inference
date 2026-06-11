package api

// Deferred-commit tests: the dispatch loop must not commit to a provider on
// boilerplate preamble chunks (role delta / Responses lifecycle events), so a
// provider that dies after its preamble — but before any real output — is
// retried invisibly instead of surfacing an in-band SSE error to a consumer
// that never received a byte.

import (
	"context"
	"encoding/json"
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

func TestIsBoilerplateChunk(t *testing.T) {
	cases := []struct {
		name  string
		chunk string
		want  bool
	}{
		{
			name:  "role-only delta with data prefix",
			chunk: `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role-only delta without data prefix",
			chunk: `{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role-only delta with trailing newlines",
			chunk: "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n",
			want:  true,
		},
		{
			name:  "role with empty content rides along",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role with null content rides along",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role with empty tool_calls array rides along",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[]},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role plus real content commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "content-only delta commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "role plus reasoning_content commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"thinking"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "tool_calls delta commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"f","arguments":""}}]},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "finish chunk commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":"stop"}]}`,
			want:  false,
		},
		{
			name:  "usage-only chunk commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}`,
			want:  false,
		},
		{
			name:  "role delta carrying usage commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}],"usage":{"prompt_tokens":10,"completion_tokens":0,"total_tokens":10}}`,
			want:  false,
		},
		{
			name:  "null usage field is still boilerplate",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}],"usage":null}`,
			want:  true,
		},
		{
			name:  "done terminator commits",
			chunk: "data: [DONE]",
			want:  false,
		},
		{
			name:  "responses created event is boilerplate",
			chunk: `data: {"type":"response.created","response":{"id":"resp_1","object":"response","status":"in_progress"}}`,
			want:  true,
		},
		{
			name:  "responses in_progress event is boilerplate",
			chunk: `data: {"type":"response.in_progress","response":{"id":"resp_1","object":"response","status":"in_progress"}}`,
			want:  true,
		},
		{
			name:  "responses output_text delta commits",
			chunk: `data: {"type":"response.output_text.delta","delta":"Hello"}`,
			want:  false,
		},
		{
			// Regression: a chat content delta that QUOTES "response.created" in
			// its content text must NOT be misread as a Responses boilerplate
			// event — it carries real output and must commit. The old substring
			// check dropped/retried it.
			name:  "chat content delta quoting response.created commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"The \"response.created\" event signals the start"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			// Same false positive for the role-only-shaped delta carrying the
			// literal in content: content is non-empty, so it commits.
			name:  "content delta quoting response.in_progress commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"see response.in_progress in the docs"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			// A genuine Responses lifecycle event (parsed top-level type) is
			// still boilerplate even when extra fields mention the string.
			name:  "real response.created event with nested mentions is boilerplate",
			chunk: `data: {"type":"response.created","response":{"id":"resp_1","object":"response","status":"in_progress","instructions":"explain response.in_progress"}}`,
			want:  true,
		},
		{
			name:  "complete chat.completion object commits",
			chunk: `data: {"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}`,
			want:  false,
		},
		{
			name:  "garbage commits",
			chunk: "data: not json at all",
			want:  false,
		},
		{
			name:  "garbage mentioning role commits",
			chunk: `data: "role" but not json`,
			want:  false,
		},
		{
			name:  "empty string commits",
			chunk: "",
			want:  false,
		},
		{
			name:  "empty choices commits",
			chunk: `data: {"object":"chat.completion.chunk","model":"role-model","choices":[]}`,
			want:  false,
		},
		{
			name:  "delta without role commits",
			chunk: `data: {"object":"chat.completion.chunk","model":"role-model","choices":[{"index":0,"delta":{},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "unknown delta field commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","audio":{"id":"a1"}},"finish_reason":null}]}`,
			want:  false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isBoilerplateChunk(tc.chunk); got != tc.want {
				t.Errorf("isBoilerplateChunk(%q) = %v, want %v", tc.chunk, got, tc.want)
			}
		})
	}
}

func TestRequestHasTools(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{name: "absent", body: `{"model":"m","messages":[]}`, want: false},
		{name: "empty array", body: `{"model":"m","tools":[]}`, want: false},
		{name: "non-empty array", body: `{"model":"m","tools":[{"type":"function","function":{"name":"f"}}]}`, want: true},
		{name: "two tools", body: `{"model":"m","tools":[{"type":"function"},{"type":"function"}]}`, want: true},
		{name: "wrong type string", body: `{"model":"m","tools":"function"}`, want: false},
		{name: "wrong type object", body: `{"model":"m","tools":{"type":"function"}}`, want: false},
		{name: "wrong type number", body: `{"model":"m","tools":3}`, want: false},
		{name: "null", body: `{"model":"m","tools":null}`, want: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var parsed map[string]any
			if err := json.Unmarshal([]byte(tc.body), &parsed); err != nil {
				t.Fatalf("unmarshal test body: %v", err)
			}
			if got := requestHasTools(parsed); got != tc.want {
				t.Errorf("requestHasTools(%s) = %v, want %v", tc.body, got, tc.want)
			}
		})
	}
}

// TestStreamingFirstChunksEmittedInOrder verifies the held-preamble plumbing:
// every element of firstChunks is written in order ahead of the relay loop,
// with the single-chunk special-casing ([DONE] swallowing, normalization)
// applied per element, and exactly one coordinator-emitted [DONE] terminator.
func TestStreamingFirstChunksEmittedInOrder(t *testing.T) {
	srv := newDeferredCommitTestServer(t)

	pr := &registry.PendingRequest{
		RequestID:  "first-chunks-order",
		Model:      "m",
		ChunkCh:    make(chan string, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
	}
	close(pr.ChunkCh) // stream already complete; only firstChunks to write

	roleChunk := `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`
	contentChunk := `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}`

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, []string{roleChunk, "data: [DONE]", contentChunk})

	body := rec.Body.String()
	roleIdx := strings.Index(body, `"role":"assistant"`)
	contentIdx := strings.Index(body, `"content":"hello"`)
	if roleIdx < 0 || contentIdx < 0 {
		t.Fatalf("body missing held role chunk or content chunk:\n%s", body)
	}
	if roleIdx > contentIdx {
		t.Errorf("held role chunk must precede the committing content chunk; body:\n%s", body)
	}
	if got := strings.Count(body, "data: [DONE]"); got != 1 {
		t.Errorf("[DONE] count = %d, want exactly 1 (provider terminators swallowed); body:\n%s", got, body)
	}
	if strings.Contains(body, `"error"`) {
		t.Errorf("clean stream must not contain an error event; body:\n%s", body)
	}
}

func newDeferredCommitTestServer(t *testing.T) *Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	return NewServer(reg, st, ServerConfig{}, logger)
}

// runDeferredCommitProvider serves the fake-provider side of the failover
// test: it answers attestation challenges and, for each inference request,
// emits the boilerplate role preamble first. failing providers then send an
// inference_error (the crash-after-preamble shape from the prod incident);
// healthy ones stream real content and complete.
func runDeferredCommitProvider(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey string, fail bool, content string) {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var raw map[string]any
		if err := json.Unmarshal(data, &raw); err != nil {
			continue
		}
		msgType, _ := raw["type"].(string)
		switch msgType {
		case protocol.TypeAttestationChallenge:
			if wErr := conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey)); wErr != nil {
				return
			}
		case protocol.TypeInferenceRequest:
			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil {
				continue
			}
			// Boilerplate preamble — emitted before any failure-prone work.
			roleChunk := `data: {"id":"chatcmpl-dc","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`
			writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey, roleChunk)
			if fail {
				errMsg := protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  inferReq.RequestID,
					Error:      "provider crashed after preamble",
					StatusCode: 500,
				}
				errData, _ := json.Marshal(errMsg)
				if wErr := conn.Write(ctx, websocket.MessageText, errData); wErr != nil {
					return
				}
				continue
			}
			contentChunk := `data: {"id":"chatcmpl-dc","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"` + content + `"},"finish_reason":null}]}`
			writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey, contentChunk)
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: inferReq.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5},
			}
			completeData, _ := json.Marshal(complete)
			if wErr := conn.Write(ctx, websocket.MessageText, completeData); wErr != nil {
				return
			}
		case protocol.TypeCancel:
			// Losing/cancelled attempts are expected — ignore.
		}
	}
}

// TestDeferredCommit_PreContentFailover is the regression test for the
// OpenRouter-partner bug: provider A sends its boilerplate role chunk and then
// dies BEFORE producing content. Because nothing was written to the consumer
// yet, the coordinator must discard the preamble and retry invisibly on
// provider B — the consumer sees a clean 200 with B's content and NO in-band
// error event.
func TestDeferredCommit_PreContentFailover(t *testing.T) {
	ts, reg, _ := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "deferred-commit-model"
	pubKeyA := testPublicKeyB64()
	pubKeyB := testPublicKeyB64()

	// A reports a much higher decode TPS so routing picks it first.
	connA := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKeyA, 500.0)
	defer connA.Close(websocket.StatusNormalClosure, "")
	connB := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKeyB, 10.0)
	defer connB.Close(websocket.StatusNormalClosure, "")

	go runDeferredCommitProvider(ctx, t, connA, pubKeyA, true, "")
	go runDeferredCommitProvider(ctx, t, connB, pubKeyB, false, "from-provider-b")

	code, body, err := sendRequest(ctx, ts.URL, "test-key", model)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (invisible retry); body = %s", code, body)
	}
	if !strings.Contains(body, "from-provider-b") {
		t.Errorf("response must carry provider B's content; body:\n%s", body)
	}
	if strings.Contains(body, `"error"`) {
		t.Errorf("pre-content provider failure must NOT surface an in-band error; body:\n%s", body)
	}
	if strings.Contains(body, "provider crashed after preamble") {
		t.Errorf("provider A's error leaked to the consumer; body:\n%s", body)
	}
	// Exactly one assistant role preamble: A's held chunk was discarded with
	// the failed attempt, B's was emitted ahead of its content.
	if got := strings.Count(body, `"role":"assistant"`); got != 1 {
		t.Errorf("role preamble count = %d, want exactly 1 (failed attempt's preamble discarded); body:\n%s", got, body)
	}
}
