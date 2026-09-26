package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestResponsesInlineMediaReachesEncryptedProviderInOrder(t *testing.T) {
	reg, _, server := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	const model = "responses-media-fixture"
	fp := startFailoverProvider(t, ctx, server, reg, failoverProviderConfig{
		Name: "responses-media", Version: "0.9.7", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			fp.serveFull(ctx, req, model, "ok")
		},
	})
	p := reg.GetProvider(fp.registryID)
	p.Mu().Lock()
	for i := range p.Models {
		p.Models[i].IsVision = true
		p.Models[i].NativeMediaTools = true
	}
	p.ToolConstraintProtocol = 1
	p.ToolConstraintModels = map[string]struct{}{model: {}}
	p.Mu().Unlock()
	setPrefixCacheProtocol(t, reg, fp, 1)
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream=%t", stream), func(t *testing.T) {
			body := fmt.Sprintf(`{"model":%q,"stream":%t,"max_output_tokens":64,"input":[{"role":"user","content":[{"type":"input_text","text":"First"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"},{"type":"input_text","text":"then"},{"type":"video_url","video_url":{"url":"data:video/mp4;base64,BBBB"}}]},{"type":"function_call","call_id":"actual","name":"describe","arguments":"{}"},{"type":"function_call_output","call_id":"actual","output":[{"type":"input_text","text":"Result"},{"type":"input_image","image_url":"data:image/png;base64,CCCC"}]},{"role":"user","content":"Keep the order."}]}`, model, stream)
			want := fmt.Sprintf(`{"model":%q,"stream":%t,"max_tokens":64,"messages":[{"role":"user","content":[{"type":"text","text":"First"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},{"type":"text","text":"then"},{"type":"video_url","video_url":{"url":"data:video/mp4;base64,BBBB"}}]},{"role":"assistant","content":"","tool_calls":[{"id":"actual","type":"function","function":{"name":"describe","arguments":"{}"}}]},{"role":"tool","tool_call_id":"actual","content":[{"type":"text","text":"Result"},{"type":"image_url","image_url":{"url":"data:image/png;base64,CCCC"}}]},{"role":"user","content":"Keep the order."}]}`, model, stream)
			got := postAndCapture(t, ctx, server, fp, "/v1/responses", "test-key", body)
			assertProviderBytes(t, got, []byte(want))
			t.Run("instructions", func(t *testing.T) {
				const instructions = "  Describe the images in result order.\n"
				var input, expected map[string]any
				if err := json.Unmarshal([]byte(body), &input); err != nil {
					t.Fatal(err)
				}
				if err := json.Unmarshal([]byte(want), &expected); err != nil {
					t.Fatal(err)
				}
				input["instructions"] = instructions
				expected["messages"] = append([]any{map[string]any{"role": "system", "content": instructions}}, expected["messages"].([]any)...)
				encoded, err := json.Marshal(input)
				if err != nil {
					t.Fatal(err)
				}
				wantBytes, err := json.Marshal(expected)
				if err != nil {
					t.Fatal(err)
				}
				got := postAndCapture(t, ctx, server, fp, "/v1/responses", "test-key", string(encoded))
				assertProviderBytes(t, got, wantBytes)
			})
		})
	}
}

func TestResponsesInlineMediaRejectsRemoteBeforeFetch(t *testing.T) {
	var hits int32
	origin := httptest.NewServer(pngHandler(t, &hits))
	defer origin.Close()
	srv, _ := testServer(t)
	makeVisionRoutableProvider(t, srv.registry, "vision", "test")
	config := mediafetch.DefaultConfig()
	config.AllowPrivateIPs = true
	config.AllowNonStandardPorts = true
	srv.mediaResolver = mediafetch.NewResolver(config, srv.logger)
	for _, toolOutput := range []bool{false, true} {
		t.Run(fmt.Sprintf("tool-output=%t", toolOutput), func(t *testing.T) {
			part := map[string]any{"type": "input_image", "image_url": origin.URL + "/image.png?token=synthetic-marker"}
			item := map[string]any{"role": "user", "content": []any{part}}
			if toolOutput {
				item = map[string]any{"type": "function_call_output", "call_id": "actual", "output": []any{part}}
			}
			body, _ := json.Marshal(map[string]any{"model": "test", "input": []any{item}, "max_output_tokens": 64})
			req := httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(body))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)
			if w.Code != 400 {
				t.Fatalf("non-inline media did not fail before dispatch: %d", w.Code)
			}
			if strings.Contains(w.Body.String(), "synthetic-marker") {
				t.Fatal("validation echoed URL contents")
			}
			if atomic.LoadInt32(&hits) != 0 {
				t.Fatal("Responses started remote fetch")
			}
		})
	}
}

func TestResponsesInlineMediaToolOutputDrivesVisionAdmission(t *testing.T) {
	body := map[string]any{"input": []any{map[string]any{"type": "function_call_output", "call_id": "actual", "output": []any{
		map[string]any{"type": "input_image", "image_url": "data:image/png;base64," + strings.Repeat("A", 4096)},
		map[string]any{"type": "video_url", "video_url": map[string]any{"url": "data:video/mp4;base64,AAAA"}},
	}}}}
	if !detectMediaRequirement(body) || countMediaParts(body) != 2 {
		t.Fatal("tool-output media lost its vision admission trait")
	}
	if got := estimatePromptTokens(body); got != 4+imagePromptTokenCost+videoPromptTokenCost {
		t.Fatalf("incorrect media-aware routing estimate: %d", got)
	}
}
