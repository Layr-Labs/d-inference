package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestInputTokenFloorIgnoresInactivePromptFields(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		t.Run(ep.path, func(t *testing.T) {
			srv, st := testServerWithConfig(t, ServerConfig{DefaultMinInputTokens: 32})
			t.Cleanup(srv.Close)
			seedRuntimeDefaultsModel(t, st, "floor-test", nil)
			srv.SyncModelCatalog()
			padding := strings.Repeat("x", 1024)
			body := map[string]any{"model": "floor-test", "messages": []any{map[string]any{"role": "user", "content": padding}}, "input": padding, "prompt": padding, "max_tokens": 32}
			if ep.field == "messages" {
				body[ep.field] = []any{map[string]any{"role": "user", "content": "hi"}}
			} else {
				body[ep.field] = "hi"
			}
			// /responses deliberately accepts a nonempty messages array as chat shape.
			if ep.field == "input" {
				delete(body, "messages")
			}
			raw, _ := json.Marshal(body)
			req := httptest.NewRequest(http.MethodPost, ep.path, strings.NewReader(string(raw)))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)
			if w.Code != 400 || !strings.Contains(w.Body.String(), "input_too_short") || !strings.Contains(w.Body.String(), "estimated 5 input tokens") {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
		})
	}
}

func TestInputTokenFloorStructuredTextMatchesLowering(t *testing.T) {
	tiny := make([]any, 28)
	for i := range tiny {
		tiny[i] = map[string]any{"type": "text", "text": "a"}
	}
	for _, tc := range []struct {
		name     string
		endpoint promptcontract.Endpoint
		body     map[string]any
		want     int
	}{
		{"responses string parts", promptcontract.EndpointResponses, map[string]any{"input": []any{map[string]any{"role": "user", "content": []any{strings.Repeat("a", 112)}}}}, 32},
		{"responses joined parts", promptcontract.EndpointResponses, map[string]any{"input": []any{map[string]any{"type": "message", "content": []any{"ab", map[string]any{"type": "input_text", "text": "c"}}}}}, 5},
		{"anthropic tiny blocks", promptcontract.EndpointMessages, map[string]any{"messages": []any{map[string]any{"role": "user", "content": tiny}}}, 11},
		{"anthropic assistant blocks", promptcontract.EndpointMessages, map[string]any{"messages": []any{map[string]any{"role": "assistant", "content": tiny}}}, 11},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.body["model"] = "m"
			raw, _ := json.Marshal(tc.body)
			lowered, err := promptcontract.LowerProviderBody(tc.endpoint, raw)
			if err != nil {
				t.Fatal(err)
			}
			object, err := decodeInferenceJSONObject(lowered)
			if err != nil {
				t.Fatal(err)
			}
			canonical, _ := messagesShape(object["messages"])
			if got := inputFloorPromptTokens(tc.body, tc.endpoint); got != tc.want || got != canonical {
				t.Fatalf("floor=%d canonical=%d want=%d", got, canonical, tc.want)
			}
			after, _ := json.Marshal(tc.body)
			if string(after) != string(raw) {
				t.Fatal("estimation mutated the consumer body")
			}
		})
	}
	// Exercise both sides of the default boundary through the actual HTTP handlers.
	h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 32}, map[string]any{"min_input_tokens": 32})
	postRuntimeDefaultsEndpoint(t, h, "/v1/responses", `{"model":"runtime-defaults-alias","input":[{"role":"user","content":["`+strings.Repeat("a", 112)+`"]}],"max_output_tokens":32}`)
	readRuntimeDefaultsProviderBody(t, h.providers[0])
	body, _ := json.Marshal(map[string]any{"model": runtimeDefaultsAlias, "messages": []any{map[string]any{"role": "user", "content": tiny}}, "max_tokens": 32})
	req := httptest.NewRequest(http.MethodPost, "/v1/messages", strings.NewReader(string(body)))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	h.coordinator.Handler().ServeHTTP(w, req)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "estimated 11 input tokens") {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestInputTokenFloorStructuredMediaHasFlatCost(t *testing.T) {
	for _, ep := range []promptcontract.Endpoint{promptcontract.EndpointResponses, promptcontract.EndpointMessages} {
		for _, n := range []int{10, 10000} {
			field := "messages"
			if ep == promptcontract.EndpointResponses {
				field = "input"
			}
			parsed := map[string]any{field: []any{map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": "abcd"},
				map[string]any{"type": "input_image", "image_url": strings.Repeat("x", n)},
				map[string]any{"type": "video_url", "video_url": strings.Repeat("y", n)},
			}}}}
			before, _ := json.Marshal(parsed)
			if got := inputFloorPromptTokens(parsed, ep); got != 1805 {
				t.Fatalf("%s bytes=%d: floor=%d want1805", ep, n, got)
			}
			after, _ := json.Marshal(parsed)
			if string(before) != string(after) {
				t.Fatal("media estimate changed the original body")
			}
		}
	}
}
