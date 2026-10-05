package inference_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestNativeMediaToolsRejectLegacyAndCallerSpoofing(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server
	p := testkit.RegisterBuildsProvider(fixture.Registry, "legacy", "test")
	p.Mu().Lock()
	p.Models[0].IsVision = true
	p.Mu().Unlock()
	body := `{"model":"test","native_media_tools":true,"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}],"tool_choice":"required"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "not supported for multimodal") {
		t.Fatalf("legacy capability guard changed: %d %s", w.Code, w.Body.String())
	}
}
