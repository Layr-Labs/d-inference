package ingress

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inferencefixture"
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
}

func TestIntrospectRequestMatchesIndependentWalks(t *testing.T) {
	for name, body := range introspectionBodies {
		t.Run(name, func(t *testing.T) {
			parsed, err := decodeInferenceJSONObject([]byte(body))
			if err != nil {
				t.Fatal(err)
			}
			wantRouting, wantBilling, wantMedia := inferencefixture.Estimates(parsed)
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
