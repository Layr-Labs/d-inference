package api

import (
	"encoding/json"
	"strings"
	"testing"
)

// introspectionBodies are request shapes that exercise every branch of the
// fused walk: plain chat, multimodal chat parts, Responses string/structured
// input, completions prompt, Anthropic source blocks, degenerate shapes that
// hit the whole-body fallback, and non-array messages.
var introspectionBodies = map[string]string{
	"chat text": `{"model":"m","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hello <world> & \"friends\"\n"}],"max_tokens":8}`,
	"chat multimodal": `{"model":"m","messages":[{"role":"user","content":[
		{"type":"text","text":"what is this"},
		{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},
		{"type":"video_url","video_url":{"url":"data:video/mp4;base64,BBBB"}},
		{"type":"mystery","payload":{"deep":[1,2,3]}},
		"stray string part"]}],"tools":[{"type":"function","function":{"name":"f"}}]}`,
	"chat tool history":    `{"model":"m","messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"{\"a\":1}"}}]},{"role":"tool","tool_call_id":"c1","content":"42"}],"tools":[]}`,
	"responses string":     `{"model":"m","input":"translate this please"}`,
	"responses structured": `{"model":"m","input":[{"role":"user","content":[{"type":"input_text","text":"hi"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]},"bare item",{"type":"message","no_content":true},7]}`,
	"completions prompt":   `{"model":"m","prompt":"Once upon a time","max_tokens":4}`,
	"anthropic image":      `{"model":"m","messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"AAAA"}},{"type":"text","text":"describe"}]}]}`,
	"messages not array":   `{"model":"m","messages":"just a string"}`,
	"messages non-map":     `{"model":"m","messages":["a",1,null,{"role":"user","content":"x"}]}`,
	"empty prompt":         `{"model":"m","messages":[],"input":"","prompt":"","max_tokens":9}`,
	"no prompt fields":     `{"model":"m","temperature":0.5}`,
	"content unusual":      `{"model":"m","messages":[{"role":"user","content":{"nested":"object"}},{"role":"user","content":12}]}`,
	// Prompt-bearing fields OUTSIDE messages/input/prompt (T10-07): tool
	// schemas on every API shape, the Anthropic top-level system prompt (string
	// or blocks) and the Responses instructions.
	"anthropic system string": `{"model":"m","system":"You are terse.","messages":[{"role":"user","content":"hi"}],"tools":[{"name":"get_weather","description":"Get weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}}]}`,
	"anthropic system blocks": `{"model":"m","system":[{"type":"text","text":"You are terse."},{"type":"text","text":"Answer in French."}],"messages":[{"role":"user","content":"hi"}]}`,
	"responses instructions":  `{"model":"m","instructions":"Reply in JSON only.","input":"summarize","tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}]}`,
	"tools only":              `{"model":"m","tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}]}`,
}

// legacyEstimates re-implements the pre-fusion estimators (independent walks,
// json.Marshal for the billing byte count) so the fused walk is pinned to them.
func legacyEstimates(parsed map[string]any) (routing, billing, media int) {
	textTokens := func(s string) int {
		if s == "" {
			return 0
		}
		if t := len(s) / 4; t > 0 {
			return t
		}
		return 1
	}
	marshalLen := func(v any) int {
		b, err := json.Marshal(v)
		if err != nil {
			return 0
		}
		return len(b)
	}
	legacyCount := func(v any) int {
		if v == nil {
			return 0
		}
		if s, ok := v.(string); ok {
			return textTokens(s)
		}
		n := marshalLen(v)
		if n == 0 {
			return 0
		}
		if n/4 < 1 {
			return 1
		}
		return n / 4
	}
	legacyUpper := func(v any) int {
		if v == nil {
			return 0
		}
		if s, ok := v.(string); ok {
			return len(s)
		}
		return marshalLen(v)
	}
	contentTokens := func(content any) int {
		switch c := content.(type) {
		case string:
			return textTokens(c)
		case []any:
			total := 0
			for _, part := range c {
				pm, ok := part.(map[string]any)
				if !ok {
					continue
				}
				typ, _ := pm["type"].(string)
				switch {
				case typ == "text" || typ == "input_text":
					if s, ok := pm["text"].(string); ok {
						total += textTokens(s)
					}
				case typ == "image_url" || typ == "input_image" || typ == "image":
					total += imagePromptTokenCost
				case typ == "video_url" || typ == "input_video" || typ == "video":
					total += videoPromptTokenCost
				default:
					total += marshalLen(pm) / 4
				}
			}
			return total
		default:
			return legacyCount(content)
		}
	}
	countMedia := func(content any) int {
		parts, ok := content.([]any)
		if !ok {
			return 0
		}
		n := 0
		for _, part := range parts {
			if pm, ok := part.(map[string]any); ok {
				if typ, _ := pm["type"].(string); isMediaPartType(typ) {
					n++
				}
			}
		}
		return n
	}
	if v, ok := parsed["messages"]; ok {
		if arr, ok := v.([]any); ok {
			for _, m := range arr {
				mm, ok := m.(map[string]any)
				if !ok {
					routing += legacyCount(m)
					continue
				}
				routing += 4 + contentTokens(mm["content"])
				media += countMedia(mm["content"])
			}
		} else {
			routing += legacyCount(v)
		}
		billing += legacyUpper(v)
	}
	if v, ok := parsed["input"]; ok {
		switch x := v.(type) {
		case string:
			routing += legacyCount(x)
		case []any:
			for _, item := range x {
				switch m := item.(type) {
				case string:
					routing += legacyCount(m)
				case map[string]any:
					content, ok := m["content"]
					if !ok {
						routing += legacyCount(m)
						continue
					}
					routing += 4 + contentTokens(content)
					media += countMedia(content)
				default:
					routing += legacyCount(item)
				}
			}
		default:
			routing += legacyCount(v)
		}
		billing += legacyUpper(v)
	}
	if v, ok := parsed["prompt"]; ok {
		routing += legacyCount(v)
		billing += legacyUpper(v)
	}
	// Independent walk of the auxiliary prompt fields (T10-07): tool schemas
	// count their JSON bytes / 4, the Anthropic system prompt and the Responses
	// instructions count like any other prompt value. Routing only — the
	// billing byte bound is untouched.
	if v, ok := parsed["tools"]; ok {
		routing += marshalLen(v) / 4
	}
	if v, ok := parsed["system"]; ok {
		routing += legacyCount(v)
	}
	if v, ok := parsed["instructions"]; ok {
		routing += legacyCount(v)
	}
	if routing == 0 {
		routing = legacyCount(parsed)
	}
	if billing == 0 {
		billing = legacyUpper(parsed)
	}
	return routing, billing, media
}

func TestIntrospectRequestMatchesIndependentWalks(t *testing.T) {
	for name, body := range introspectionBodies {
		t.Run(name, func(t *testing.T) {
			parsed, err := decodeInferenceJSONObject([]byte(body))
			if err != nil {
				t.Fatal(err)
			}
			wantRouting, wantBilling, wantMedia := legacyEstimates(parsed)
			shape := introspectRequest(parsed)
			if got := shape.routingPromptTokens(parsed); got != wantRouting {
				t.Errorf("routing = %d, want %d", got, wantRouting)
			}
			if got := shape.billingPromptTokens(parsed); got != wantBilling {
				t.Errorf("billing = %d, want %d", got, wantBilling)
			}
			if shape.mediaParts != wantMedia {
				t.Errorf("media parts = %d, want %d", shape.mediaParts, wantMedia)
			}
			tools, _ := parsed["tools"].([]any)
			if shape.hasTools != (len(tools) > 0) {
				t.Errorf("hasTools = %v", shape.hasTools)
			}
			// The thin wrappers must agree with the fused walk.
			if estimatePromptTokens(parsed) != wantRouting ||
				estimateBillingPromptTokens(parsed) != wantBilling ||
				countMediaParts(parsed) != wantMedia ||
				detectMediaRequirement(parsed) != (wantMedia > 0) ||
				requestHasTools(parsed) != shape.hasTools {
				t.Errorf("wrapper drift: routing=%d billing=%d media=%d vision=%v tools=%v",
					estimatePromptTokens(parsed), estimateBillingPromptTokens(parsed),
					countMediaParts(parsed), detectMediaRequirement(parsed), requestHasTools(parsed))
			}
		})
	}
}

// The whole-body fallback must observe mutations made AFTER introspection
// (the handler injects max_tokens and rewrites the model between the two
// call sites), so it is evaluated lazily at the call site.
func TestRequestShapeFallbackIsLazy(t *testing.T) {
	parsed := map[string]any{"model": "m", "messages": nil}
	shape := introspectRequest(parsed)
	before := shape.routingPromptTokens(parsed)
	beforeBilling := shape.billingPromptTokens(parsed)
	parsed["model"] = "a-much-longer-concrete-build-identifier"
	parsed["max_tokens"] = 8192
	if got := shape.routingPromptTokens(parsed); got <= before {
		t.Fatalf("routing fallback ignored later mutations: %d <= %d", got, before)
	}
	if got := shape.billingPromptTokens(parsed); got <= beforeBilling {
		t.Fatalf("billing fallback ignored later mutations: %d <= %d", got, beforeBilling)
	}
	if got := estimatePromptTokens(parsed); got != shape.routingPromptTokens(parsed) {
		t.Fatalf("wrapper = %d, shape = %d", got, shape.routingPromptTokens(parsed))
	}
}

// toolSchemaOfJSONLength returns a one-tool array whose JSON encoding is exactly
// jsonLen bytes, so the routing term it adds is exactly jsonLen/4 tokens.
func toolSchemaOfJSONLength(t *testing.T, jsonLen int) []any {
	t.Helper()
	const overhead = len(`[{"type":"function","function":{"name":"f","description":""}}]`)
	if jsonLen < overhead {
		t.Fatalf("jsonLen %d below the %d-byte envelope", jsonLen, overhead)
	}
	tools := []any{map[string]any{
		"type": "function",
		"function": map[string]any{
			"name":        "f",
			"description": strings.Repeat("x", jsonLen-overhead),
		},
	}}
	if got := jsonValueLen(tools); got != jsonLen {
		t.Fatalf("tools JSON length = %d, want %d", got, jsonLen)
	}
	return tools
}

// TestRoutingShapeCountsToolsSystemInstructions pins the T10-07 terms on all
// three API shapes: a 6 KB tools array adds exactly 1,536 routing tokens on
// top of the message walk (tool-less bodies are unchanged), the Anthropic
// system prompt and the Responses instructions count like prompt text, a body
// whose only prompt-bearing field is tools no longer falls back to the
// whole-body marshal (no double count), and the billing bound is untouched.
// Before the change every one of these deltas was 0.
func TestRoutingShapeCountsToolsSystemInstructions(t *testing.T) {
	const toolsJSONLen = 6144 // 6 KB of schema → 1,536 tokens
	tools := toolSchemaOfJSONLength(t, toolsJSONLen)
	instructions := strings.Repeat("i", 400) // 100 tokens
	system := strings.Repeat("s", 800)       // 200 tokens

	chat := map[string]any{"model": "m", "messages": []any{map[string]any{"role": "user", "content": "hello"}}}
	chatBase := estimatePromptTokens(chat)
	if chatBase != 4+1 {
		t.Fatalf("tool-less chat estimate = %d, want 5 (4/message + len/4)", chatBase)
	}
	chat["tools"] = tools
	if got := estimatePromptTokens(chat); got != chatBase+toolsJSONLen/4 {
		t.Fatalf("chat with 6 KB tools = %d, want %d (+%d)", got, chatBase+toolsJSONLen/4, toolsJSONLen/4)
	}
	if got := estimateBillingPromptTokens(chat); got != estimateBillingPromptTokens(map[string]any{"model": "m", "messages": chat["messages"]}) {
		t.Fatalf("billing bound moved with tools: %d", got)
	}

	responses := map[string]any{"model": "m", "input": "summarize"}
	respBase := estimatePromptTokens(responses)
	responses["instructions"] = instructions
	responses["tools"] = tools
	if got, want := estimatePromptTokens(responses), respBase+100+toolsJSONLen/4; got != want {
		t.Fatalf("responses with instructions+tools = %d, want %d", got, want)
	}

	anthropic := map[string]any{"model": "m", "messages": []any{map[string]any{"role": "user", "content": "hi"}}}
	anthBase := estimatePromptTokens(anthropic)
	anthropic["system"] = system
	anthropic["tools"] = tools
	if got, want := estimatePromptTokens(anthropic), anthBase+200+toolsJSONLen/4; got != want {
		t.Fatalf("anthropic with system+tools = %d, want %d", got, want)
	}
	anthropic["system"] = []any{map[string]any{"type": "text", "text": system}}
	blocks := estimatePromptTokens(anthropic)
	if blocks <= anthBase+toolsJSONLen/4 {
		t.Fatalf("anthropic system blocks not counted: %d", blocks)
	}

	// tools as the only prompt-bearing field: counted once (the whole-body
	// fallback, which would also include the model field, must not run).
	toolsOnly := map[string]any{"model": strings.Repeat("m", 400), "tools": tools}
	if got := estimatePromptTokens(toolsOnly); got != toolsJSONLen/4 {
		t.Fatalf("tools-only body = %d, want exactly %d (no whole-body fallback)", got, toolsJSONLen/4)
	}

	// Both handlers read the same walk.
	shape := introspectRequest(chat)
	if got := shape.routingPromptTokens(chat); got != estimatePromptTokens(chat) {
		t.Fatalf("introspectRequest routing = %d, estimatePromptTokens = %d", got, estimatePromptTokens(chat))
	}
}
