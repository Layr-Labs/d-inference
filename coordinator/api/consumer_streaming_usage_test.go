package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestUsageChunkParseAndFinalize covers the parse-once + finalize helpers.
func TestUsageChunkParseAndFinalize(t *testing.T) {
	usageChunk := `data: {"object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`
	pr := &registry.PendingRequest{Model: "gpt-oss-20b"}

	obj, ok := parseUsageOnlyStreamChunk(usageChunk)
	if !ok {
		t.Fatal("expected the usage-only chunk to be detected + parsed")
	}
	out := finalizeUsageChunk(obj, protocol.UsageInfo{CompletionTokens: 50, ReasoningTokens: 8}, pr)
	if !strings.Contains(out, `"reasoning_tokens":8`) {
		t.Fatalf("expected reasoning_tokens spliced into usage; got %s", out)
	}

	// A content delta and a usage:null chunk are NOT usage-only chunks.
	if _, ok := parseUsageOnlyStreamChunk(`data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"x"}}]}`); ok {
		t.Fatal("a content delta must NOT be treated as a usage-only chunk")
	}
	if _, ok := parseUsageOnlyStreamChunk(`data: {"object":"chat.completion.chunk","choices":[],"usage":null}`); ok {
		t.Fatal("a usage:null chunk must NOT be treated as a usage-only chunk")
	}

	// No reasoning → no completion_tokens_details added.
	obj2, _ := parseUsageOnlyStreamChunk(usageChunk)
	if plain := finalizeUsageChunk(obj2, protocol.UsageInfo{CompletionTokens: 50}, pr); strings.Contains(plain, "completion_tokens_details") {
		t.Fatalf("expected no reasoning detail when ReasoningTokens=0; got %s", plain)
	}

	// Build id rewritten to the public alias.
	obj3, _ := parseUsageOnlyStreamChunk(usageChunk)
	prAlias := &registry.PendingRequest{Model: "gpt-oss-20b", PublicModel: "gpt-oss"}
	aliased := finalizeUsageChunk(obj3, protocol.UsageInfo{CompletionTokens: 50, ReasoningTokens: 8}, prAlias)
	if !strings.Contains(aliased, `"model":"gpt-oss"`) || strings.Contains(aliased, `"model":"gpt-oss-20b"`) {
		t.Fatalf("expected build id rewritten to the public alias; got %s", aliased)
	}
}

// TestStreamingChatReasoningTokensInUsage proves chat-completions STREAMING now
// reports the reasoning breakdown in the terminal usage chunk (the bug: reasoning
// was lumped into completion with no completion_tokens_details).
func TestStreamingChatReasoningTokensInUsage(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	pr := &registry.PendingRequest{
		RequestID:  "job-1",
		Model:      "gpt-oss-20b",
		ChunkCh:    make(chan string, 8),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
	}
	// Provider streams a content delta, then the include_usage chunk WITHOUT a
	// reasoning detail, then closes and reports the authoritative split via CompleteCh.
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 50, ReasoningTokens: 8}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil, false)

	body := rec.Body.String()
	if !strings.Contains(body, `"reasoning_tokens":8`) {
		t.Fatalf("streaming usage missing reasoning_tokens; body=\n%s", body)
	}
	if !strings.Contains(body, `"completion_tokens":50`) {
		t.Fatalf("completion_tokens should stay 50 (reasoning is a subset detail); body=\n%s", body)
	}
	if !strings.Contains(body, `"content":"hi"`) || !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("expected the content delta and [DONE]; body=\n%s", body)
	}
	if strings.Count(body, `"usage":{`) != 1 {
		t.Fatalf("expected exactly one usage chunk (held + augmented, not doubled); body=\n%s", body)
	}
}

// TestStreamingChatUsageOnlyFirstChunk covers the zero-delta case: a completion
// that streams no content/reasoning deltas, so the include_usage frame is the very
// FIRST chunk handed to the handler. It must still be held and have the reasoning
// breakdown spliced in (not emitted raw), and must not be doubled.
func TestStreamingChatUsageOnlyFirstChunk(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	pr := &registry.PendingRequest{
		RequestID:  "job-1",
		Model:      "gpt-oss-20b",
		ChunkCh:    make(chan string, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
	}
	// No deltas at all — the stream closes immediately; the authoritative split
	// arrives on CompleteCh.
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 50, ReasoningTokens: 8}

	firstChunk := `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, []string{firstChunk}, false)

	body := rec.Body.String()
	if !strings.Contains(body, `"reasoning_tokens":8`) {
		t.Fatalf("usage-only first chunk must still get reasoning_tokens spliced; body=\n%s", body)
	}
	if !strings.Contains(body, `"completion_tokens":50`) {
		t.Fatalf("completion_tokens should stay 50; body=\n%s", body)
	}
	if strings.Count(body, `"usage":{`) != 1 {
		t.Fatalf("expected exactly one usage chunk (held + augmented, not raw + doubled); body=\n%s", body)
	}
	if !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("expected [DONE] terminator; body=\n%s", body)
	}
}

// TestStreamingChatSingleDoneSignatureBeforeIt covers the SplittyDev report:
// the provider's own "data: [DONE]" was forwarded, then the coordinator
// appended a bare {"choices":[],se_signature,...} event and a SECOND [DONE].
// SDKs treat the first [DONE] as final and choke on the malformed trailer.
// Now: provider [DONE] swallowed, the signature rides a fully-shaped chunk,
// and exactly one [DONE] terminates the stream.
func TestStreamingChatSingleDoneSignatureBeforeIt(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	pr := &registry.PendingRequest{
		RequestID:    "job-1",
		Model:        "gpt-oss-20b",
		SESignature:  "sig-abc",
		ResponseHash: "hash-def",
		ChunkCh:      make(chan string, 8),
		ErrorCh:      make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:   make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"gpt-oss-20b","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"gpt-oss-20b","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`
	pr.ChunkCh <- "data: [DONE]" // the provider's own terminator — must be swallowed
	close(pr.ChunkCh)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil, false)

	body := rec.Body.String()
	if got := strings.Count(body, "data: [DONE]"); got != 1 {
		t.Fatalf("expected exactly ONE [DONE]; got %d\nbody:\n%s", got, body)
	}
	if !strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
		t.Fatalf("[DONE] must be the FINAL event — nothing may trail it; body:\n%s", body)
	}
	sigIdx := strings.Index(body, `"se_signature":"sig-abc"`)
	doneIdx := strings.Index(body, "data: [DONE]")
	if sigIdx == -1 || sigIdx > doneIdx {
		t.Fatalf("signature event must precede the single [DONE]; body:\n%s", body)
	}
	// The signature event must be a fully-shaped chunk for strict decoders.
	var sigLine string
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "se_signature") {
			sigLine = strings.TrimPrefix(line, "data: ")
			break
		}
	}
	var sigObj map[string]any
	if err := json.Unmarshal([]byte(sigLine), &sigObj); err != nil {
		t.Fatalf("signature event is not valid JSON: %v", err)
	}
	for _, k := range []string{"id", "object", "created", "model", "choices", "response_hash"} {
		if _, present := sigObj[k]; !present {
			t.Fatalf("signature event missing required field %q (breaks strict SDKs); got: %s", k, sigLine)
		}
	}
	if sigObj["object"] != "chat.completion.chunk" {
		t.Fatalf("signature event object must be chat.completion.chunk; got %v", sigObj["object"])
	}
}

// TestStreamingChatSignatureRidesUsageChunk: with stream_options.include_usage
// (a held usage-only chunk), the SE signature is spliced into that final
// well-formed chunk — no separate signature event, single [DONE].
func TestStreamingChatSignatureRidesUsageChunk(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	pr := &registry.PendingRequest{
		RequestID:    "job-1",
		Model:        "gpt-oss-20b",
		SESignature:  "sig-abc",
		ResponseHash: "hash-def",
		ChunkCh:      make(chan string, 8),
		ErrorCh:      make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:   make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"gpt-oss-20b","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`
	pr.ChunkCh <- "data: [DONE]"
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 50, ReasoningTokens: 8}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil, false)

	body := rec.Body.String()
	if got := strings.Count(body, "data: [DONE]"); got != 1 {
		t.Fatalf("expected exactly ONE [DONE]; got %d\nbody:\n%s", got, body)
	}
	if got := strings.Count(body, "se_signature"); got != 1 {
		t.Fatalf("signature must appear exactly once (on the usage chunk); got %d\nbody:\n%s", got, body)
	}
	// One line carries usage + reasoning + signature together.
	var found bool
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "se_signature") {
			found = strings.Contains(line, `"reasoning_tokens":8`) &&
				strings.Contains(line, `"usage"`) &&
				strings.Contains(line, `"response_hash":"hash-def"`)
		}
	}
	if !found {
		t.Fatalf("signature must ride the final usage chunk (with reasoning spliced); body:\n%s", body)
	}
	if !strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
		t.Fatalf("[DONE] must be the final event; body:\n%s", body)
	}
}
