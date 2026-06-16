package mediafetch

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// --- helpers ---------------------------------------------------------------

// pngBytes returns `total` bytes that http.DetectContentType sniffs as image/png
// (the 8-byte PNG signature followed by zero padding).
func pngBytes(total int) []byte {
	sig := []byte("\x89PNG\r\n\x1a\n")
	if total < len(sig) {
		total = len(sig)
	}
	b := make([]byte, total)
	copy(b, sig)
	return b
}

func webmBytes(total int) []byte {
	sig := []byte("\x1aE\xdf\xa3")
	if total < len(sig) {
		total = len(sig)
	}
	b := make([]byte, total)
	copy(b, sig)
	return b
}

// devConfig returns a Config usable against httptest (loopback) servers.
func devConfig() Config {
	c := DefaultConfig()
	c.AllowPrivateIPs = true // httptest binds 127.0.0.1
	return c
}

// chatBody builds a parsed chat-completions body with the given user content parts.
func chatBody(parts ...map[string]any) map[string]any {
	anyParts := make([]any, len(parts))
	for i, p := range parts {
		anyParts[i] = p
	}
	return map[string]any{
		"model": "test",
		"messages": []any{
			map[string]any{"role": "user", "content": anyParts},
		},
	}
}

func imagePartObj(url string) map[string]any {
	return map[string]any{"type": "image_url", "image_url": map[string]any{"url": url}}
}

func imagePartStr(url string) map[string]any {
	return map[string]any{"type": "image_url", "image_url": url}
}

// firstImageURL extracts messages[0].content[idx].image_url(.url) as a string.
func firstImageURL(t *testing.T, parsed map[string]any, idx int) string {
	t.Helper()
	parts := parsed["messages"].([]any)[0].(map[string]any)["content"].([]any)
	switch v := parts[idx].(map[string]any)["image_url"].(type) {
	case string:
		return v
	case map[string]any:
		s, _ := v["url"].(string)
		return s
	}
	return ""
}

// --- tests -----------------------------------------------------------------

func TestResolveSuccessObjectForm(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(64))
	}))
	defer srv.Close()

	r := NewResolver(devConfig(), nil)
	parsed := chatBody(
		map[string]any{"type": "text", "text": "what is this?"},
		imagePartObj(srv.URL+"/cat.png"),
	)
	res, err := r.Resolve(context.Background(), parsed)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !res.Changed || res.Count != 1 {
		t.Fatalf("Result = %+v, want Changed=true Count=1", res)
	}
	if got := firstImageURL(t, parsed, 1); !strings.HasPrefix(got, "data:image/png;base64,") {
		t.Errorf("image not inlined; url = %.40q", got)
	}
}

func TestResolveSuccessStringForm(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(64))
	}))
	defer srv.Close()

	r := NewResolver(devConfig(), nil)
	parsed := chatBody(imagePartStr(srv.URL + "/cat.png"))
	if _, err := r.Resolve(context.Background(), parsed); err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got := firstImageURL(t, parsed, 0); !strings.HasPrefix(got, "data:image/png;base64,") {
		t.Errorf("string-form image not inlined; url = %.40q", got)
	}
}

func TestResolveVideo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(webmBytes(64))
	}))
	defer srv.Close()

	r := NewResolver(devConfig(), nil)
	parsed := map[string]any{
		"model": "test",
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "video_url", "video_url": map[string]any{"url": srv.URL + "/clip.webm"}},
		}}},
	}
	if _, err := r.Resolve(context.Background(), parsed); err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	parts := parsed["messages"].([]any)[0].(map[string]any)["content"].([]any)
	got, _ := parts[0].(map[string]any)["video_url"].(map[string]any)["url"].(string)
	if !strings.HasPrefix(got, "data:video/webm;base64,") {
		t.Errorf("video not inlined; url = %.40q", got)
	}
}

func TestResolveMixedDataAndRemoteAndText(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(48))
	}))
	defer srv.Close()

	const inlineData = "data:image/png;base64,iVBORw0KGgo="
	r := NewResolver(devConfig(), nil)
	parsed := chatBody(
		map[string]any{"type": "text", "text": "compare"},
		imagePartObj(inlineData),   // already inline → untouched
		imagePartObj(srv.URL+"/x"), // remote → fetched
	)
	res, err := r.Resolve(context.Background(), parsed)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if res.Count != 1 {
		t.Errorf("Count = %d, want 1 (only the remote URL)", res.Count)
	}
	if got := firstImageURL(t, parsed, 1); got != inlineData {
		t.Errorf("inline data: URI was modified: %.40q", got)
	}
	if got := firstImageURL(t, parsed, 2); !strings.HasPrefix(got, "data:image/png;base64,") {
		t.Errorf("remote URL not inlined: %.40q", got)
	}
}

func TestResolveTextOnlyNoOp(t *testing.T) {
	r := NewResolver(devConfig(), nil)
	parsed := map[string]any{"model": "test", "messages": []any{
		map[string]any{"role": "user", "content": "just text"},
	}}
	res, err := r.Resolve(context.Background(), parsed)
	if err != nil || res.Changed {
		t.Fatalf("text-only: res=%+v err=%v, want no-op", res, err)
	}
}

func TestResolveMultipleImages(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(pngBytes(32))
	}))
	defer srv.Close()

	r := NewResolver(devConfig(), nil)
	parsed := chatBody(
		imagePartObj(srv.URL+"/1.png"),
		imagePartObj(srv.URL+"/2.png"),
		imagePartObj(srv.URL+"/3.png"),
	)
	res, err := r.Resolve(context.Background(), parsed)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if res.Count != 3 || atomic.LoadInt32(&hits) != 3 {
		t.Fatalf("Count=%d hits=%d, want 3/3", res.Count, hits)
	}
}

func mustErr(t *testing.T, parsed map[string]any, r *Resolver, wantStatus int, wantCode string) {
	t.Helper()
	_, err := r.Resolve(context.Background(), parsed)
	if err == nil {
		t.Fatalf("Resolve: expected error %s/%d", wantCode, wantStatus)
	}
	me, ok := err.(*Error)
	if !ok {
		t.Fatalf("error type = %T, want *Error: %v", err, err)
	}
	if me.Status != wantStatus || me.Code != wantCode {
		t.Errorf("error = %d/%s, want %d/%s", me.Status, me.Code, wantStatus, wantCode)
	}
}

func TestResolveDisabledRejectsRemote(t *testing.T) {
	cfg := devConfig()
	cfg.Enabled = false
	r := NewResolver(cfg, nil)
	// Fake URL: never fetched because the disabled gate fires first.
	parsed := chatBody(imagePartObj("https://example.com/cat.png"))
	mustErr(t, parsed, r, http.StatusBadRequest, "remote_media_disabled")
}

func TestResolveTooManyParts(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(16))
	}))
	defer srv.Close()
	cfg := devConfig()
	cfg.MaxParts = 2
	r := NewResolver(cfg, nil)
	parsed := chatBody(
		imagePartObj(srv.URL+"/1"), imagePartObj(srv.URL+"/2"), imagePartObj(srv.URL+"/3"),
	)
	mustErr(t, parsed, r, http.StatusBadRequest, "too_many_media_parts")
}

func TestResolvePerFileTooLargeHonestContentLength(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(200)) // httptest sets Content-Length=200
	}))
	defer srv.Close()
	cfg := devConfig()
	cfg.MaxFileBytes = 50
	r := NewResolver(cfg, nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/big.png")), r, http.StatusRequestEntityTooLarge, "media_too_large")
}

func TestResolvePerFileTooLargeChunked(t *testing.T) {
	// Flush mid-write so the response is chunked (Content-Length unknown). This
	// proves the io.LimitReader cap — not just the Content-Length pre-check —
	// enforces the per-file limit even when the server lies/omits the length.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fl, _ := w.(http.Flusher)
		w.Write(pngBytes(30))
		if fl != nil {
			fl.Flush()
		}
		w.Write(make([]byte, 60)) // total 90 > cap
	}))
	defer srv.Close()
	cfg := devConfig()
	cfg.MaxFileBytes = 40
	r := NewResolver(cfg, nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/big.png")), r, http.StatusRequestEntityTooLarge, "media_too_large")
}

func TestResolvePerRequestTotalTooLarge(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(100))
	}))
	defer srv.Close()
	cfg := devConfig()
	cfg.MaxFileBytes = 100  // each 100-byte file fits the per-file cap exactly
	cfg.MaxTotalBytes = 150 // but the sum (200) exceeds the per-request cap
	r := NewResolver(cfg, nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/1"), imagePartObj(srv.URL+"/2")),
		r, http.StatusRequestEntityTooLarge, "media_too_large")
}

func TestResolveNonMediaContentType(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png") // lying header
		w.Write([]byte("<!DOCTYPE html><html>not an image</html>"))
	}))
	defer srv.Close()
	r := NewResolver(devConfig(), nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/fake.png")), r, http.StatusBadRequest, "media_invalid_type")
}

func TestResolveUpstreamError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusNotFound)
	}))
	defer srv.Close()
	r := NewResolver(devConfig(), nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/missing.png")), r, http.StatusBadGateway, "media_fetch_failed")
}

func TestResolveTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
		w.Write(pngBytes(16))
	}))
	defer srv.Close()
	cfg := devConfig()
	cfg.FetchTimeout = 80 * time.Millisecond
	r := NewResolver(cfg, nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/slow.png")), r, http.StatusRequestTimeout, "media_fetch_timeout")
}

func TestResolveSSRFBlocksLoopback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(16))
	}))
	defer srv.Close()
	// Strict policy: the httptest server is on 127.0.0.1, so the dial Control
	// hook must refuse it.
	cfg := DefaultConfig() // AllowPrivateIPs=false
	r := NewResolver(cfg, nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/x.png")), r, http.StatusForbidden, "media_blocked")
}

func TestResolveRedirectToDisallowedScheme(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "file:///etc/passwd", http.StatusFound)
	}))
	defer srv.Close()
	r := NewResolver(devConfig(), nil) // allow loopback so the first hop dials
	mustErr(t, chatBody(imagePartObj(srv.URL+"/redir")), r, http.StatusBadRequest, "media_invalid_scheme")
}

func TestResolveRedirectLoopDepthCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/again", http.StatusFound) // self-redirect forever
	}))
	defer srv.Close()
	r := NewResolver(devConfig(), nil)
	// Exceeding maxRedirects surfaces as errBlockedHost → media_blocked.
	mustErr(t, chatBody(imagePartObj(srv.URL+"/start")), r, http.StatusForbidden, "media_blocked")
}

func TestHasRemoteMedia(t *testing.T) {
	withRemote := chatBody(imagePartObj("https://example.com/a.png"))
	if !HasRemoteMedia(withRemote) {
		t.Error("HasRemoteMedia = false for a remote image_url")
	}
	withData := chatBody(imagePartObj("data:image/png;base64,iVBORw0KGgo="))
	if HasRemoteMedia(withData) {
		t.Error("HasRemoteMedia = true for an inline data: URI")
	}
	textOnly := map[string]any{"messages": []any{map[string]any{"role": "user", "content": "hi"}}}
	if HasRemoteMedia(textOnly) {
		t.Error("HasRemoteMedia = true for a text-only request")
	}
}

// jsonRoundTrip guards that a resolved body re-marshals to valid JSON the
// downstream encrypt path can forward.
func TestResolvedBodyReMarshals(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(32))
	}))
	defer srv.Close()
	r := NewResolver(devConfig(), nil)
	parsed := chatBody(imagePartObj(srv.URL + "/x.png"))
	if _, err := r.Resolve(context.Background(), parsed); err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	b, err := json.Marshal(parsed)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	if !strings.Contains(string(b), "data:image/png;base64,") {
		t.Errorf("re-marshaled body missing inlined data: URI")
	}
}
