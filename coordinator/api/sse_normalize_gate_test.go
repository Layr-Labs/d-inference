package api

import (
	"strings"
	"testing"
)

// legacyNormalizeGate is the gate normalizeSSEChunk used before the
// single-pass scan: seven strings.Contains for `"<key>":null` plus two for
// the reasoning aliases. The single-pass gate must agree with it on every
// input so normalizeSSEChunk's output stays byte-identical.
func legacyNormalizeGate(line string) (needsNullFix, needsReasoning bool) {
	needsNullFix = strings.Contains(line, `"content":null`) ||
		strings.Contains(line, `"tool_calls":null`) ||
		strings.Contains(line, `"usage":null`) ||
		strings.Contains(line, `"reasoning":null`) ||
		strings.Contains(line, `"reasoning_content":null`) ||
		strings.Contains(line, `"refusal":null`) ||
		strings.Contains(line, `"system_fingerprint":null`)
	needsReasoning = strings.Contains(line, `"reasoning"`) ||
		strings.Contains(line, `"reasoning_content"`)
	return needsNullFix, needsReasoning
}

// sseGateCorpus covers the shapes that distinguish the gates: every fixable
// key, the finish_reason:null present on every delta (must not trigger),
// reasoning aliases vs reasoning_details / reasoning_tokens, spaced and
// quoted nulls, nulls inside string values, key look-alikes, non-JSON lines.
var sseGateCorpus = []struct {
	name  string
	chunk string
}{
	{"content delta, finish_reason null only",
		`data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}`},
	{"role-only preamble",
		`data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`},
	{"all fixable nulls",
		`data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":null,"reasoning_content":null,"reasoning":null,"refusal":null},"finish_reason":null}],"usage":null,"system_fingerprint":null}`},
	{"content null only", `data: {"choices":[{"delta":{"content":null},"finish_reason":null}]}`},
	{"tool_calls null only", `data: {"choices":[{"delta":{"tool_calls":null},"finish_reason":null}]}`},
	{"usage null only", `data: {"choices":[],"usage":null}`},
	{"refusal null only", `data: {"choices":[{"delta":{"refusal":null}}]}`},
	{"system_fingerprint null only", `data: {"choices":[],"system_fingerprint":null}`},
	{"reasoning null only", `data: {"choices":[{"delta":{"reasoning":null}}]}`},
	{"reasoning_content null only", `data: {"choices":[{"delta":{"reasoning_content":null}}]}`},
	{"finish null before content null",
		`data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":null}}]}`},
	{"usage object final chunk",
		`data: {"id":"c","choices":[],"usage":{"prompt_tokens":150,"completion_tokens":83,"total_tokens":233}}`},
	{"usage with reasoning_tokens detail (no alias)",
		`data: {"id":"c","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"completion_tokens_details":{"reasoning_tokens":7}}}`},
	{"reasoning_content delta",
		`data: {"choices":[{"index":0,"delta":{"reasoning_content":"think"},"finish_reason":null}]}`},
	{"reasoning delta",
		`data: {"choices":[{"index":0,"delta":{"reasoning":"think"},"finish_reason":null}]}`},
	{"both aliases, differing",
		`data: {"choices":[{"index":0,"delta":{"reasoning":"a","reasoning_content":"b"},"finish_reason":null}]}`},
	{"reasoning_details only (no alias)",
		`data: {"choices":[{"index":0,"delta":{"content":"x","reasoning_details":[{"type":"reasoning.text","text":"t"}]},"finish_reason":null}]}`},
	{"reasoning_details with content null",
		`data: {"choices":[{"index":0,"delta":{"content":null,"reasoning_details":[]},"finish_reason":null}]}`},
	{"spaced null (pretty JSON) must not trigger",
		`data: {"choices": [{"delta": {"content": null}, "finish_reason": null}]}`},
	{"string value \"null\"", `data: {"choices":[{"delta":{"content":"null"},"finish_reason":null}]}`},
	{"null pattern inside string value",
		`data: {"choices":[{"delta":{"content":"see \"usage\":null here"},"finish_reason":null}]}`},
	{"key look-alike xcontent", `data: {"choices":[{"delta":{"xcontent":null},"finish_reason":null}]}`},
	{"key look-alike contents", `data: {"choices":[{"delta":{"contents":null},"finish_reason":null}]}`},
	{"reasoning look-alike reasonings", `data: {"choices":[{"delta":{"reasonings":"x"},"finish_reason":null}]}`},
	{"content mentioning reasoning word", `data: {"choices":[{"delta":{"content":"my reasoning is"},"finish_reason":null}]}`},
	{"done marker", `data: [DONE]`},
	{"empty", ``},
	{"no data prefix", `{"choices":[{"delta":{"content":null}}]}`},
	{"garbage with null key", `data: not json "content":null`},
	{"garbage without keys", `data: nullnullnull`},
	{"trailing null literal", `data: {"a":null`},
	{"null at very start", `null`},
	{"finish chunk", `data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`},
	{"tool call delta",
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"f","arguments":"{"}}]},"finish_reason":null}]}`},
	{"responses event", `data: {"type":"response.output_text.delta","delta":"hi","sequence_number":3}`},
	{"multiline SSE group with event field",
		"event: message\ndata: {\"choices\":[{\"delta\":{\"content\":null},\"finish_reason\":null}]}"},
}

// The single-pass gate agrees with the legacy nine-Contains gate on the whole
// corpus, and normalizeSSEChunk's output is exactly what the legacy gate
// would have produced (unchanged chunk when gated off, the parsed rewrite
// when gated on).
func TestSSENormalizeGateMatchesLegacy(t *testing.T) {
	for _, tc := range sseGateCorpus {
		t.Run(tc.name, func(t *testing.T) {
			line := strings.TrimPrefix(tc.chunk, "data: ")
			wantNull, wantReasoning := legacyNormalizeGate(line)
			if got := sseChunkNeedsNullFix(line); got != wantNull {
				t.Errorf("sseChunkNeedsNullFix = %v, legacy = %v", got, wantNull)
			}
			if got := sseChunkHasReasoningField(line); got != wantReasoning {
				t.Errorf("sseChunkHasReasoningField = %v, legacy = %v", got, wantReasoning)
			}
			want := tc.chunk
			if wantNull || wantReasoning {
				want = rewriteSSEChunkFields(tc.chunk, line)
			}
			if got := normalizeSSEChunk(tc.chunk); got != want {
				t.Errorf("normalizeSSEChunk output diverged from legacy-gated output:\n got: %s\nwant: %s", got, want)
			}
		})
	}
}

// legacyNormalizeSSEChunk is normalizeSSEChunk with the pre-change gate, for
// a same-binary before/after benchmark.
func legacyNormalizeSSEChunk(chunk string) string {
	line := strings.TrimPrefix(chunk, "data: ")
	needsNullFix, needsReasoning := legacyNormalizeGate(line)
	if !needsNullFix && !needsReasoning {
		return chunk
	}
	return rewriteSSEChunkFields(chunk, line)
}

// BenchmarkNormalizeSSEChunkGate compares the legacy nine-Contains gate with
// the single-pass gate on the benchmark corpus (fast-path cases are where the
// gate dominates; slow-path cases are dominated by the JSON round-trip).
func BenchmarkNormalizeSSEChunkGate(b *testing.B) {
	cases := []struct {
		name  string
		chunk string
	}{
		{"content_delta", `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"content":"Hello world"},"finish_reason":null}]}`},
		{"usage_final", `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[],"usage":{"prompt_tokens":150,"completion_tokens":83,"total_tokens":233}}`},
		{"reasoning_details_passthrough", `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"content":"Hello","reasoning_details":[{"type":"reasoning.text","text":"t","index":0}]},"finish_reason":null}]}`},
		{"with_nulls", `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":null,"reasoning_content":null},"finish_reason":null}],"usage":null,"system_fingerprint":null}`},
		{"reasoning_delta", `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"reasoning_content":"Let me think about this"},"finish_reason":null}]}`},
	}
	impls := []struct {
		name string
		fn   func(string) string
	}{
		{"legacy", legacyNormalizeSSEChunk},
		{"single_pass", normalizeSSEChunk},
	}
	for _, tc := range cases {
		for _, impl := range impls {
			b.Run(tc.name+"/"+impl.name, func(b *testing.B) {
				b.ReportAllocs()
				for range b.N {
					_ = impl.fn(tc.chunk)
				}
			})
		}
	}
}

// Nulls that are not the first `null` in the line are still found: the scan
// must continue past finish_reason:null rather than stop at the first hit.
func TestSSENullFixScanContinuesPastFirstNull(t *testing.T) {
	line := `{"choices":[{"finish_reason":null,"logprobs":null,"index":0,"delta":{"role":"assistant","content":null}}]}`
	if !sseChunkNeedsNullFix(line) {
		t.Fatal("content:null after two other nulls was not detected")
	}
	if sseChunkNeedsNullFix(`{"choices":[{"finish_reason":null,"logprobs":null,"delta":{"content":"x"}}]}`) {
		t.Fatal("non-fixable nulls must not trigger")
	}
}
