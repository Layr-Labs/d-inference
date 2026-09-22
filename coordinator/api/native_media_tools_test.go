package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNativeMediaToolsRejectLegacyAndCallerSpoofing(t *testing.T) {
	srv, _ := testServer(t)
	makeVisionRoutableProvider(t, srv.registry, "legacy", "test")
	body := `{"model":"test","native_media_tools":true,"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}],"tool_choice":"required"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "not supported for multimodal") {
		t.Fatalf("legacy capability guard changed: %d %s", w.Code, w.Body.String())
	}
}

func TestNativeMediaToolsTraitsInspectOnlyToolResultMedia(t *testing.T) {
	for _, raw := range []string{
		`{"messages":[{"role":"tool","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`,
		`{"input":[{"type":"function_call_output","call_id":"actual","output":[{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}]}`,
	} {
		p, err := decodeInferenceJSONObject([]byte(raw))
		if err != nil || !requestHasMediaToolResults(p) {
			t.Fatal("tool media not recognized")
		}
	}
	for _, raw := range []string{
		`{"messages":[{"role":"user","content":[{"type":"image_url"}]}]}`,
		`{"messages":[{"role":"tool","content":"{\"type\":\"input_image\"}"}]}`,
		`{"tools":[{"function":{"parameters":{"type":"image_url"}}}],"metadata":{"role":"tool","content":[{"type":"image_url"}]}}`,
	} {
		p, err := decodeInferenceJSONObject([]byte(raw))
		if err != nil || requestHasMediaToolResults(p) {
			t.Fatal("non-media data acquired a capability requirement")
		}
	}
}
