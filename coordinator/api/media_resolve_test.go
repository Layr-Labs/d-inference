package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// makeVisionRoutableProvider registers an online, routable, vision-capable
// provider for model so a media request clears visionToolsFailFast and reaches
// the post-billing media-resolution step the HTTP-path tests below exercise
// (resolution now runs after admission/billing, so the request must first pass
// the vision gate). Empty test catalog => modelAllowedByCatalogLocked allows it.
func makeVisionRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) {
	t.Helper()
	p := makeRoutableProvider(t, reg, id, model)
	p.Mu().Lock()
	for i := range p.Models {
		if p.Models[i].ID == model {
			p.Models[i].IsVision = true
		}
	}
	p.Mu().Unlock()
}

// minimalMediaServer builds a Server with only the fields resolveRemoteMedia
// touches, using a resolver that permits loopback so httptest works.
func minimalMediaServer(cfg mediafetch.Config) *Server {
	return &Server{
		logger:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		mediaResolver: mediafetch.NewResolver(cfg, nil),
	}
}

func pngHandler(hits *int32) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if hits != nil {
			atomic.AddInt32(hits, 1)
		}
		w.Write([]byte("\x89PNG\r\n\x1a\n\x00\x00\x00\x00")) // sniffs image/png
	}
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

func TestResolveRemoteMediaInlinesOnSuccess(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	s := minimalMediaServer(cfg)

	media := httptest.NewServer(pngHandler(nil))
	defer media.Close()

	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	w := httptest.NewRecorder()

	out, ok := s.resolveRemoteMedia(w, req, raw, parsed)
	if !ok {
		t.Fatalf("resolveRemoteMedia ok=false, body=%s", w.Body.String())
	}
	if !bytes.Contains(out, []byte("data:image/png;base64,")) {
		t.Errorf("returned body not inlined: %.80s", out)
	}
	if bytes.Contains(out, []byte("http://")) {
		t.Errorf("returned body still carries an http URL: %.120s", out)
	}
}

func TestResolveRemoteMediaSealedRejectsWithoutFetching(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	s := minimalMediaServer(cfg)

	var hits int32
	media := httptest.NewServer(pngHandler(&hits))
	defer media.Close()

	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	// Mark the request as sender-sealed.
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	req = req.WithContext(context.WithValue(req.Context(), sealedCtxKey, struct{}{}))
	w := httptest.NewRecorder()

	out, ok := s.resolveRemoteMedia(w, req, raw, parsed)
	if ok {
		t.Fatalf("sealed request with a remote URL should be rejected")
	}
	if out != nil {
		t.Errorf("expected nil body on rejection")
	}
	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
	if !strings.Contains(w.Body.String(), "data:") {
		t.Errorf("error should instruct the sender to use a data: URI: %s", w.Body.String())
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Errorf("sealed request triggered %d fetch(es); must be 0", n)
	}
}

func TestResolveRemoteMediaSealedAllowsInlineData(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	s := minimalMediaServer(cfg)

	parsed := map[string]any{
		"model": "test",
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "image_url", "image_url": map[string]any{
				"url": "data:image/png;base64,iVBORw0KGgo=",
			}},
		}}},
	}
	raw, _ := json.Marshal(parsed)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	req = req.WithContext(context.WithValue(req.Context(), sealedCtxKey, struct{}{}))
	w := httptest.NewRecorder()

	out, ok := s.resolveRemoteMedia(w, req, raw, parsed)
	if !ok {
		t.Fatalf("sealed request with inline data: must be allowed, body=%s", w.Body.String())
	}
	if !bytes.Equal(out, raw) {
		t.Errorf("inline-data sealed body should pass through unchanged")
	}
}

// --- full HTTP path through srv.Handler() ----------------------------------

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
	srv, _ := testServer(t) // default resolver: AllowPrivateIPs=false (strict)
	makeVisionRoutableProvider(t, srv.registry, "vision-ssrf", "test")

	media := httptest.NewServer(pngHandler(nil))
	defer media.Close()

	body, _ := chatBodyBytes(t, media.URL+"/x.png") // loopback -> must be blocked
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

func TestChatCompletionsRemoteMediaDisabled(t *testing.T) {
	srv, _ := testServer(t)
	makeVisionRoutableProvider(t, srv.registry, "vision-disabled", "test")
	cfg := mediafetch.DefaultConfig()
	cfg.Enabled = false
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)

	// Fake public URL: never fetched because the disabled gate fires first.
	body, _ := chatBodyBytes(t, "https://example.com/cat.png")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
	if code := errType(t, w.Body.Bytes()); code != "remote_media_disabled" {
		t.Errorf("error code = %q, want remote_media_disabled", code)
	}
}

// TestPreludeDefersRemoteMediaResolution locks in the gating fix (finding #1): the
// shared parseInferencePrelude must NOT fetch/inline remote media. Resolution is
// deferred to each handler AFTER token admission + the balance reservation, so an
// authenticated-but-unfunded/over-quota request can never drive coordinator-side
// fetches. A remote URL therefore survives the prelude unchanged and no fetch
// occurs. Before the fix the prelude resolved media inline, so this fails: the URL
// is replaced with a data: URI and the origin sees a fetch. The resolver here
// permits loopback, so it WOULD inline successfully if the prelude (wrongly)
// invoked it — proving the deferral, not a fetch failure.
func TestPreludeDefersRemoteMediaResolution(t *testing.T) {
	srv, _ := testServer(t)
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)

	var hits int32
	media := httptest.NewServer(pngHandler(&hits))
	defer media.Close()

	body, _ := chatBodyBytes(t, media.URL+"/x.png")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	w := httptest.NewRecorder()

	prelude, ok := srv.parseInferencePrelude(w, req)
	if !ok {
		t.Fatalf("prelude unexpectedly failed: %s", w.Body.String())
	}
	if !bytes.Contains(prelude.rawBody, []byte("http://")) {
		t.Errorf("prelude inlined the remote URL; media resolution must be deferred to post-billing")
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Errorf("prelude fetched media %d time(s); must be 0 (resolution is deferred to post-billing)", n)
	}
}

func TestChatCompletionsBodyTooLarge(t *testing.T) {
	srv, _ := testServer(t)

	// Build a body just over the per-handler inference cap (the tighter cap the
	// prelude applies before parsing; the global bodyLimitMiddleware is looser).
	big := bytes.Repeat([]byte("a"), maxInferenceBodyBytes+1024)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(big))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413; body=%.200s", w.Code, w.Body.String())
	}
	if code := errType(t, w.Body.Bytes()); code != "invalid_request_error" {
		t.Errorf("error code = %q, want invalid_request_error", code)
	}
}
