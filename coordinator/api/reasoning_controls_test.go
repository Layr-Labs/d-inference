package api

// Reasoning-disable contract tests (OpenRouter baseline: "Expected reasoning
// length to be at most 0"). Every documented spelling of "reasoning off" must
// canonicalize into the ONE shape providers decode (reasoning.enabled=false),
// and a disabled/excluded request's response must never carry reasoning text.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func parseTestBody(t *testing.T, body string) map[string]any {
	t.Helper()
	parsed, err := decodeInferenceJSONObject([]byte(body))
	if err != nil {
		t.Fatalf("unmarshal test body: %v", err)
	}
	return parsed
}

func reasoningEnabledValue(t *testing.T, parsed map[string]any) (bool, bool) {
	t.Helper()
	reasoning, ok := parsed["reasoning"].(map[string]any)
	if !ok {
		return false, false
	}
	enabled, ok := reasoning["enabled"].(bool)
	return enabled, ok
}

func TestNormalizeReasoningControls(t *testing.T) {
	cases := []struct {
		name         string
		body         string
		wantMutated  bool
		wantSuppress bool
		// wantEnabled/wantEnabledSet describe reasoning.enabled after the call.
		wantEnabled    bool
		wantEnabledSet bool
		check          func(t *testing.T, parsed map[string]any)
	}{
		{
			name:           "canonical enabled=false passes through unmutated",
			body:           `{"model":"m","reasoning":{"enabled":false}}`,
			wantMutated:    false,
			wantSuppress:   true,
			wantEnabled:    false,
			wantEnabledSet: true,
		},
		{
			name:           "openrouter effort none disables",
			body:           `{"model":"m","reasoning":{"effort":"none"}}`,
			wantMutated:    true,
			wantSuppress:   true,
			wantEnabled:    false,
			wantEnabledSet: true,
			check: func(t *testing.T, parsed map[string]any) {
				reasoning := parsed["reasoning"].(map[string]any)
				if _, ok := reasoning["effort"]; ok {
					t.Errorf("effort %q must be removed from the forwarded body", reasoning["effort"])
				}
			},
		},
		{
			name:           "effort none is case- and whitespace-insensitive",
			body:           `{"model":"m","reasoning":{"effort":" NONE "}}`,
			wantMutated:    true,
			wantSuppress:   true,
			wantEnabled:    false,
			wantEnabledSet: true,
		},
		{
			name:           "top-level reasoning_effort none disables",
			body:           `{"model":"m","reasoning_effort":"none"}`,
			wantMutated:    true,
			wantSuppress:   true,
			wantEnabled:    false,
			wantEnabledSet: true,
			check: func(t *testing.T, parsed map[string]any) {
				if _, ok := parsed["reasoning_effort"]; ok {
					t.Error("reasoning_effort \"none\" must be removed from the forwarded body")
				}
			},
		},
		{
			name:         "non-none efforts are untouched",
			body:         `{"model":"m","reasoning_effort":"high","reasoning":{"effort":"high"}}`,
			wantMutated:  false,
			wantSuppress: false,
			check: func(t *testing.T, parsed map[string]any) {
				if parsed["reasoning_effort"] != "high" {
					t.Errorf("reasoning_effort = %v, want high", parsed["reasoning_effort"])
				}
				if effort := parsed["reasoning"].(map[string]any)["effort"]; effort != "high" {
					t.Errorf("reasoning.effort = %v, want high", effort)
				}
			},
		},
		{
			name:           "explicit enabled=true wins over effort none",
			body:           `{"model":"m","reasoning":{"enabled":true,"effort":"none"}}`,
			wantMutated:    true, // the unusable "none" effort is still removed
			wantSuppress:   false,
			wantEnabled:    true,
			wantEnabledSet: true,
		},
		{
			name:           "explicit enabled=true wins over top-level effort none",
			body:           `{"model":"m","reasoning":{"enabled":true},"reasoning_effort":"none"}`,
			wantMutated:    true,
			wantSuppress:   false,
			wantEnabled:    true,
			wantEnabledSet: true,
		},
		{
			name:         "exclude=true suppresses without disabling",
			body:         `{"model":"m","reasoning":{"exclude":true}}`,
			wantMutated:  false,
			wantSuppress: true,
		},
		{
			name:         "include_reasoning=false suppresses without disabling",
			body:         `{"model":"m","include_reasoning":false}`,
			wantMutated:  false,
			wantSuppress: true,
		},
		{
			name:         "include_reasoning=true is a no-op",
			body:         `{"model":"m","include_reasoning":true}`,
			wantMutated:  false,
			wantSuppress: false,
		},
		{
			name:           "anthropic thinking disabled maps to enabled=false",
			body:           `{"model":"m","thinking":{"type":"disabled"}}`,
			wantMutated:    true,
			wantSuppress:   true,
			wantEnabled:    false,
			wantEnabledSet: true,
		},
		{
			name:           "anthropic thinking enabled maps to enabled=true",
			body:           `{"model":"m","thinking":{"type":"enabled","budget_tokens":2048}}`,
			wantMutated:    true,
			wantSuppress:   false,
			wantEnabled:    true,
			wantEnabledSet: true,
		},
		{
			name:           "explicit enabled=false wins over thinking enabled",
			body:           `{"model":"m","reasoning":{"enabled":false},"thinking":{"type":"enabled"}}`,
			wantMutated:    false,
			wantSuppress:   true,
			wantEnabled:    false,
			wantEnabledSet: true,
		},
		{
			name:         "no reasoning fields is a no-op",
			body:         `{"model":"m","messages":[{"role":"user","content":"hi"}]}`,
			wantMutated:  false,
			wantSuppress: false,
		},
		{
			// OpenRouter parameter hierarchy: the reasoning object's concrete
			// effort wins over a contradictory legacy top-level "none".
			name:         "concrete object effort wins over top-level effort none",
			body:         `{"model":"m","reasoning":{"effort":"high"},"reasoning_effort":"none"}`,
			wantMutated:  true, // the unusable top-level "none" is still removed
			wantSuppress: false,
			check: func(t *testing.T, parsed map[string]any) {
				if _, ok := parsed["reasoning_effort"]; ok {
					t.Error("top-level reasoning_effort \"none\" must be removed")
				}
				if effort := parsed["reasoning"].(map[string]any)["effort"]; effort != "high" {
					t.Errorf("reasoning.effort = %v, want high", effort)
				}
				if _, ok := parsed["reasoning"].(map[string]any)["enabled"]; ok {
					t.Error("a concrete object effort must not be rewritten into a disable")
				}
			},
		},
		{
			name:         "non-boolean and null reasoning shapes are tolerated",
			body:         `{"model":"m","reasoning":{"enabled":null,"effort":7,"exclude":"yes"},"reasoning_effort":3,"include_reasoning":null}`,
			wantMutated:  false,
			wantSuppress: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			parsed := parseTestBody(t, tc.body)
			mutated, suppress := normalizeReasoningControls(parsed)
			if mutated != tc.wantMutated {
				t.Errorf("mutated = %v, want %v", mutated, tc.wantMutated)
			}
			if suppress != tc.wantSuppress {
				t.Errorf("suppress = %v, want %v", suppress, tc.wantSuppress)
			}
			if tc.wantEnabledSet {
				enabled, ok := reasoningEnabledValue(t, parsed)
				if !ok {
					t.Fatalf("reasoning.enabled missing after normalization: %v", parsed)
				}
				if enabled != tc.wantEnabled {
					t.Errorf("reasoning.enabled = %v, want %v", enabled, tc.wantEnabled)
				}
			}
			if tc.check != nil {
				tc.check(t, parsed)
			}

			// Idempotence: the canonical body must not mutate again.
			if mutatedAgain, suppressAgain := normalizeReasoningControls(parsed); mutatedAgain {
				t.Error("second normalization pass mutated an already-canonical body")
			} else if suppressAgain != suppress {
				t.Errorf("second pass suppress = %v, want %v", suppressAgain, suppress)
			}
		})
	}
}

// The canonical disable must survive the exact forward-body marshal providers
// decode — reasoning.enabled=false is the ONLY switch the Swift engine reads.
func TestNormalizeReasoningControlsForwardBody(t *testing.T) {
	for _, body := range []string{
		`{"model":"m","reasoning":{"effort":"none"}}`,
		`{"model":"m","reasoning_effort":"none"}`,
		`{"model":"m","thinking":{"type":"disabled"}}`,
		`{"model":"m","reasoning":{"enabled":false}}`,
	} {
		parsed := parseTestBody(t, body)
		normalizeReasoningControls(parsed)
		forward, err := marshalForwardBody(parsed)
		if err != nil {
			t.Fatalf("marshalForwardBody: %v", err)
		}
		if !strings.Contains(string(forward), `"reasoning":{"enabled":false}`) {
			t.Errorf("forward body for %s lacks the canonical disable: %s", body, forward)
		}
		if strings.Contains(string(forward), `"none"`) {
			t.Errorf("forward body for %s still carries a \"none\" effort: %s", body, forward)
		}
	}
}

func TestStripReasoningFromStreamChunk(t *testing.T) {
	cases := []struct {
		name     string
		chunk    string
		want     string
		wantDrop bool
	}{
		{
			name:     "reasoning-only delta is dropped",
			chunk:    `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning":"thinking...","reasoning_content":"thinking..."},"finish_reason":null}]}`,
			wantDrop: true,
		},
		{
			name:  "mixed delta keeps content and loses reasoning",
			chunk: `data: {"choices":[{"index":0,"delta":{"content":"Hello","reasoning_content":"hmm"},"finish_reason":null}]}`,
		},
		{
			name:  "role preamble with empty reasoning fields is kept",
			chunk: `data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"","reasoning_content":""},"finish_reason":null}]}`,
		},
		{
			name:  "finish chunk with reasoning delta is kept",
			chunk: `data: {"choices":[{"index":0,"delta":{"reasoning_content":"tail"},"finish_reason":"stop"}]}`,
		},
		{
			name:  "usage-bearing reasoning chunk is kept",
			chunk: `data: {"choices":[{"index":0,"delta":{"reasoning":"tail"},"finish_reason":null}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3,"completion_tokens_details":{"reasoning_tokens":2}}}`,
		},
		{
			name:  "content-only chunk passes through untouched",
			chunk: `data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`,
			want:  `data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`,
		},
		{
			name:  "message-shaped choice is stripped but never dropped",
			chunk: `data: {"choices":[{"index":0,"message":{"role":"assistant","content":"hi","reasoning":"deep thought","reasoning_content":"deep thought"},"finish_reason":null}]}`,
		},
		{
			name:  "done terminator passes through untouched",
			chunk: "data: [DONE]",
			want:  "data: [DONE]",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, drop := stripReasoningFromStreamChunk(tc.chunk)
			if drop != tc.wantDrop {
				t.Fatalf("drop = %v, want %v (chunk %q)", drop, tc.wantDrop, got)
			}
			if tc.wantDrop {
				return
			}
			if tc.want != "" && got != tc.want {
				t.Fatalf("chunk rewritten unexpectedly:\n got: %s\nwant: %s", got, tc.want)
			}
			payload := strings.TrimPrefix(strings.TrimSpace(got), "data: ")
			if payload == "[DONE]" {
				return
			}
			var obj map[string]any
			if err := json.Unmarshal([]byte(payload), &obj); err != nil {
				t.Fatalf("stripped chunk is not valid JSON: %v\n%s", err, got)
			}
			for _, choice := range obj["choices"].([]any) {
				for _, key := range []string{"delta", "message"} {
					member, _ := choice.(map[string]any)[key].(map[string]any)
					for _, field := range reasoningDeltaFields {
						if _, ok := member[field]; ok {
							t.Errorf("%s still carries %q: %s", key, field, got)
						}
					}
				}
			}
			// Usage accounting must survive suppression untouched.
			if strings.Contains(tc.chunk, `"usage":{`) && !strings.Contains(got, `"reasoning_tokens":2`) {
				t.Errorf("usage reasoning_tokens must be preserved: %s", got)
			}
		})
	}
}

func TestStripReasoningFromCompleteResponse(t *testing.T) {
	raw := `{"object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"4","reasoning":"let me think","reasoning_content":"let me think"},"finish_reason":"stop"}],"usage":{"completion_tokens_details":{"reasoning_tokens":12}}}`
	var obj map[string]any
	if err := json.Unmarshal([]byte(raw), &obj); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	stripReasoningFromCompleteResponse(obj)
	message := obj["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if _, ok := message["reasoning"]; ok {
		t.Error("message.reasoning must be removed")
	}
	if _, ok := message["reasoning_content"]; ok {
		t.Error("message.reasoning_content must be removed")
	}
	if message["content"] != "4" {
		t.Errorf("content = %v, want 4", message["content"])
	}
	details := obj["usage"].(map[string]any)["completion_tokens_details"].(map[string]any)
	if details["reasoning_tokens"].(float64) != 12 {
		t.Error("usage reasoning_tokens must be preserved")
	}
}

// End-to-end through the chat SSE writer: a suppressed-reasoning stream must
// deliver content, finish, and usage — and not one byte of reasoning text.
func TestStreamingSuppressReasoning(t *testing.T) {
	srv := newDeferredCommitTestServer(t)

	pr := &registry.PendingRequest{
		RequestID:         "suppress-reasoning-stream",
		Model:             "m",
		SuppressReasoning: true,
		ChunkCh:           make(chan string, 8),
		ErrorCh:           make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:        make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":" and more"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"The answer","reasoning_content":"overlap"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":9,"total_tokens":14,"completion_tokens_details":{"reasoning_tokens":7}}}`
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 9, ReasoningTokens: 7}

	roleChunk := `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`
	reasoningFirst := `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":"thinking hard"},"finish_reason":null}]}`

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, []string{roleChunk, reasoningFirst}, false)

	body := rec.Body.String()
	for _, leaked := range []string{"thinking hard", " and more", "overlap"} {
		if strings.Contains(body, leaked) {
			t.Errorf("reasoning text %q leaked into a suppressed stream:\n%s", leaked, body)
		}
	}
	if !strings.Contains(body, `"content":"The answer"`) {
		t.Errorf("content delta missing from suppressed stream:\n%s", body)
	}
	if !strings.Contains(body, `"role":"assistant"`) {
		t.Errorf("role preamble missing from suppressed stream:\n%s", body)
	}
	if !strings.Contains(body, `"finish_reason":"stop"`) {
		t.Errorf("finish chunk missing from suppressed stream:\n%s", body)
	}
	// Token accounting is unaffected by text suppression.
	if !strings.Contains(body, `"reasoning_tokens":7`) {
		t.Errorf("usage reasoning_tokens missing from suppressed stream:\n%s", body)
	}
}

// A terminal chunk carrying BOTH finish_reason and a trailing reasoning delta
// is held by the relay loop before suppression runs and re-emitted at stream
// end — finalizeFinishChunk must strip it there.
func TestStreamingSuppressReasoningOnHeldFinishChunk(t *testing.T) {
	srv := newDeferredCommitTestServer(t)

	pr := &registry.PendingRequest{
		RequestID:         "suppress-reasoning-finish",
		Model:             "m",
		SuppressReasoning: true,
		ChunkCh:           make(chan string, 4),
		ErrorCh:           make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:        make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":"terminal tail"},"finish_reason":"stop"}]}`
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil, false)

	body := rec.Body.String()
	if strings.Contains(body, "terminal tail") {
		t.Errorf("reasoning text on the held finish chunk leaked:\n%s", body)
	}
	if !strings.Contains(body, `"finish_reason":"stop"`) {
		t.Errorf("finish_reason missing from suppressed stream:\n%s", body)
	}
}

// End-to-end through the non-streaming writer: the reconstructed message must
// carry no reasoning field when suppression is on.
func TestNonStreamingSuppressReasoning(t *testing.T) {
	srv := newDeferredCommitTestServer(t)

	pr := &registry.PendingRequest{
		RequestID:         "suppress-reasoning-nonstream",
		Model:             "m",
		SuppressReasoning: true,
		ChunkCh:           make(chan string, 4),
		ErrorCh:           make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:        make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":"pondering"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"42"},"finish_reason":"stop"}]}`
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 4, ReasoningTokens: 2}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleNonStreamingResponseWithFirstChunk(rec, req, pr, nil)

	body := rec.Body.String()
	if strings.Contains(body, "pondering") {
		t.Errorf("reasoning text leaked into a suppressed non-streaming response:\n%s", body)
	}
	if !strings.Contains(body, `"content":"42"`) {
		t.Errorf("content missing from suppressed non-streaming response:\n%s", body)
	}
	var resp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}
	message := resp["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if _, ok := message["reasoning"]; ok {
		t.Errorf("message.reasoning present in suppressed response: %v", message)
	}
}

// The Responses-API streaming emitter must not emit reasoning items or
// summary events for a suppressed request, while finish() keeps the buffered
// text so legacy providers (no tokenizer-accurate ReasoningTokens) still
// report accurate usage.
func TestResponsesStreamingSuppressReasoning(t *testing.T) {
	pr := &registry.PendingRequest{
		RequestID:         "suppress-reasoning-responses",
		Model:             "m",
		IsResponsesAPI:    true,
		SuppressReasoning: true,
	}
	rec := httptest.NewRecorder()
	emitter := newResponsesStreamEmitter(rec, noopFlusher{}, pr, "resp_x", 1)
	emitter.start()
	emitter.handleChunk(`data: {"choices":[{"index":0,"delta":{"reasoning_content":"hidden thought"},"finish_reason":null}]}`)
	emitter.handleChunk(`data: {"choices":[{"index":0,"delta":{"content":"Visible"},"finish_reason":null}]}`)
	emitter.handleChunk(`data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`)
	// Legacy usage: no provider-side reasoning count — finish() must fall
	// back to the buffered (suppressed) text for the usage breakdown.
	emitter.finish(protocol.UsageInfo{PromptTokens: 2, CompletionTokens: 6})

	body := rec.Body.String()
	if strings.Contains(body, "hidden thought") {
		t.Errorf("reasoning text leaked into a suppressed Responses stream:\n%s", body)
	}
	if strings.Contains(body, "reasoning_summary") || strings.Contains(body, `"type":"reasoning"`) {
		t.Errorf("reasoning events/items emitted on a suppressed Responses stream:\n%s", body)
	}
	if !strings.Contains(body, `"delta":"Visible"`) {
		t.Errorf("content delta missing from suppressed Responses stream:\n%s", body)
	}
	if !strings.Contains(body, `"reasoning_tokens":6`) {
		t.Errorf("legacy usage fallback lost under suppression:\n%s", body)
	}
}

// The non-streaming SSE-reconstruction path must keep the legacy text-based
// usage fallback: suppression hides the text, it does not unbill it.
func TestNonStreamingSuppressReasoningKeepsLegacyUsageFallback(t *testing.T) {
	srv := newDeferredCommitTestServer(t)

	pr := &registry.PendingRequest{
		RequestID:         "suppress-reasoning-legacy-usage",
		Model:             "m",
		SuppressReasoning: true,
		ChunkCh:           make(chan string, 4),
		ErrorCh:           make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:        make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":"quiet"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}`
	close(pr.ChunkCh)
	// Legacy provider: reasoning happened but ReasoningTokens is unreported.
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 5}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleNonStreamingResponseWithFirstChunk(rec, req, pr, nil)

	body := rec.Body.String()
	if strings.Contains(body, "quiet") {
		t.Errorf("reasoning text leaked:\n%s", body)
	}
	if !strings.Contains(body, `"reasoning_tokens":5`) {
		t.Errorf("legacy text-based reasoning_tokens fallback lost under suppression:\n%s", body)
	}
}

type noopFlusher struct{}

func (noopFlusher) Flush() {}

// The raw complete-object passthrough (provider returns one chat.completion
// object instead of SSE deltas) must strip reasoning the same way.
func TestNonStreamingPassthroughSuppressReasoning(t *testing.T) {
	srv := newDeferredCommitTestServer(t)

	pr := &registry.PendingRequest{
		RequestID:         "suppress-reasoning-passthrough",
		Model:             "m",
		SuppressReasoning: true,
		ChunkCh:           make(chan string, 2),
		ErrorCh:           make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:        make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"done","reasoning_content":"chain of thought"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}`
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 2, CompletionTokens: 3, ReasoningTokens: 1}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleNonStreamingResponseWithFirstChunk(rec, req, pr, nil)

	body := rec.Body.String()
	if strings.Contains(body, "chain of thought") {
		t.Errorf("reasoning text leaked through the passthrough path:\n%s", body)
	}
	if !strings.Contains(body, `"content":"done"`) {
		t.Errorf("content missing from passthrough response:\n%s", body)
	}
}
