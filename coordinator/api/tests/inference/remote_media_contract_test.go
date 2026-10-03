package inference_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func makeVisionRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) {
	t.Helper()
	p := testkit.RegisterBuildsProvider(reg, id, model)
	p.Mu().Lock()
	p.Models[0].IsVision = true
	p.Mu().Unlock()
}

func chatBodyBytes(t *testing.T, imageURL string) ([]byte, map[string]any) {
	t.Helper()
	parsed := map[string]any{
		"model": "test",
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "image_url", "image_url": map[string]any{"url": imageURL}},
		}}},
	}
	raw, err := json.Marshal(parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Re-parse so the returned map is independent of the bytes (mirrors prelude).
	var fresh map[string]any
	if err := json.Unmarshal(raw, &fresh); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return raw, fresh
}

func errType(t *testing.T, body []byte) string {
	t.Helper()
	var resp struct {
		Error struct {
			Type string `json:"type"`
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal error body %q: %v", body, err)
	}
	if resp.Error.Code != "" {
		return resp.Error.Code
	}
	return resp.Error.Type
}

func TestChatCompletionsRemoteMediaSSRFBlocked(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowNonStandardPorts = true // isolate connect-time loopback blocking from the port gate
	fixture := testkit.New(t, api.ServerConfig{MediaFetch: &cfg})
	srv := fixture.Server
	makeVisionRoutableProvider(t, fixture.Registry, "vision-ssrf", "test")

	media := httptest.NewServer(pngHandler(t, nil))
	defer media.Close()

	body, _ := chatBodyBytes(t, media.URL+"/x.png") // loopback must be blocked at dial time
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403; body=%s", w.Code, w.Body.String())
	}
	if code := errType(t, w.Body.Bytes()); code != "media_blocked" {
		t.Errorf("error code = %q, want media_blocked", code)
	}
}

func TestChatCompletionsRemoteMediaSuccessInlines(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true // loopback httptest origin
	cfg.AllowNonStandardPorts = true
	fixture := testkit.New(t, api.ServerConfig{MediaFetch: &cfg})
	srv := fixture.Server
	makeVisionRoutableProvider(t, fixture.Registry, "vision-ok", "test")

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	body, _ := chatBodyBytes(t, media.URL+"/cat.png")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	// The fetch+inline succeeded (origin was hit exactly once) and the request
	// proceeded past validation into dispatch. No live provider WebSocket exists
	// in this harness, so the terminal status is a downstream dispatch/queue
	// outcome; anything but the media-gate 4xx family proves the media step.
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("origin hit %d time(s), want exactly 1; status=%d body=%.200s", n, w.Code, w.Body.String())
	}
	if w.Code == http.StatusBadRequest || w.Code == http.StatusForbidden {
		t.Errorf("request died at the media gate: %d %s", w.Code, w.Body.String())
	}
}

func TestChatCompletionsRemoteMediaDisabledLegacyReject(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.Enabled = false
	fixture := testkit.New(t, api.ServerConfig{MediaFetch: &cfg})
	srv := fixture.Server
	makeVisionRoutableProvider(t, fixture.Registry, "vision-disabled", "test")

	// Fake public URL: never fetched because the disabled gate fires first
	// (legacy pre-dispatch rejection, invalid_request_error).
	body, _ := chatBodyBytes(t, "https://example.com/cat.png")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
	if code := errType(t, w.Body.Bytes()); code != "invalid_request_error" {
		t.Errorf("error code = %q, want invalid_request_error (legacy reject)", code)
	}
	if !strings.Contains(w.Body.String(), "data:") {
		t.Errorf("legacy rejection must point at the data: URI contract: %s", w.Body.String())
	}
}
