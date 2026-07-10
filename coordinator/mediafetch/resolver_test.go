package mediafetch

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// --- helpers ---------------------------------------------------------------

// pngPrefix returns `total` bytes whose PREFIX sniffs as image/png. Only usable
// in tests that fail before content validation (size caps, timeouts, SSRF) —
// the zero-padded body does not survive the pixel gate's header parse. Success
// paths must serve validPNG(t) (sniff_test.go) instead.
func pngPrefix(total int) []byte {
	sig := []byte("\x89PNG\r\n\x1a\n")
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
	c.AllowPrivateIPs = true       // httptest binds 127.0.0.1
	c.AllowNonStandardPorts = true // httptest chooses an ephemeral port
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

func videoPartObj(url string) map[string]any {
	return map[string]any{"type": "video_url", "video_url": map[string]any{"url": url}}
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

func serveBytes(data []byte) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(data)
	}))
}

// --- tests -----------------------------------------------------------------

func TestResolveSuccessObjectForm(t *testing.T) {
	srv := serveBytes(validPNG(t))
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
	srv := serveBytes(validPNG(t))
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

func TestResolveVideoMP4(t *testing.T) {
	srv := serveBytes(mp4Bytes(64))
	defer srv.Close()

	r := NewResolver(devConfig(), nil)
	parsed := chatBody(videoPartObj(srv.URL + "/clip.mp4"))
	if _, err := r.Resolve(context.Background(), parsed); err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	parts := parsed["messages"].([]any)[0].(map[string]any)["content"].([]any)
	got, _ := parts[0].(map[string]any)["video_url"].(map[string]any)["url"].(string)
	if !strings.HasPrefix(got, "data:video/mp4;base64,") {
		t.Errorf("video not inlined; url = %.40q", got)
	}
}

func TestResolveVideoWebMRejected(t *testing.T) {
	// AVFoundation (the provider's video decoder) cannot decode WebM — inlining
	// it would waste a dispatch just to 400 at the provider, so the coordinator
	// rejects it up front.
	srv := serveBytes([]byte("\x1aE\xdf\xa3................"))
	defer srv.Close()
	r := NewResolver(devConfig(), nil)
	mustErr(t, chatBody(videoPartObj(srv.URL+"/clip.webm")), r, http.StatusBadRequest, "media_invalid_type")
}

func TestResolveKindMismatch(t *testing.T) {
	srv := serveBytes(mp4Bytes(64)) // an image_url part pointing at a video
	defer srv.Close()
	r := NewResolver(devConfig(), nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/sneaky")), r, http.StatusBadRequest, "media_kind_mismatch")
}

func TestResolvePixelBombRejected(t *testing.T) {
	srv := serveBytes(bombPNG(t)) // tiny file, 400 MP declared dimensions
	defer srv.Close()
	r := NewResolver(devConfig(), nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/bomb.png")), r, http.StatusRequestEntityTooLarge, "media_too_large")
}

func TestResolveMixedDataAndRemoteAndText(t *testing.T) {
	srv := serveBytes(validPNG(t))
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
	img := validPNG(t)
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(img)
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

func TestResolveNonStandardPortRejectedBeforeDial(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(validPNG(t))
	}))
	defer srv.Close()

	cfg := DefaultConfig()
	cfg.AllowPrivateIPs = true // isolate the port policy
	r := NewResolver(cfg, nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/cat.png")), r, http.StatusForbidden, "media_blocked")
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("non-standard port rejection must happen before dial; origin hits=%d", n)
	}
}

func TestResolveTooManyParts(t *testing.T) {
	srv := serveBytes(validPNG(t))
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
	srv := serveBytes(pngPrefix(200)) // httptest sets Content-Length=200
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
		w.Write(pngPrefix(30))
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
	img := validPNG(t)
	srv := serveBytes(img)
	defer srv.Close()
	cfg := devConfig()
	cfg.MaxFileBytes = int64(len(img))        // each file fits the per-file cap exactly
	cfg.MaxTotalBytes = int64(2*len(img) - 1) // but the sum exceeds the per-request cap
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
		w.Write(validPNG(t))
	}))
	defer srv.Close()
	cfg := devConfig()
	cfg.FetchTimeout = 80 * time.Millisecond
	r := NewResolver(cfg, nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/slow.png")), r, http.StatusRequestTimeout, "media_fetch_timeout")
}

func TestResolveSSRFBlocksLoopback(t *testing.T) {
	srv := serveBytes(validPNG(t))
	defer srv.Close()
	// Strict policy: the httptest server is on 127.0.0.1, so the dial Control
	// hook must refuse it.
	cfg := DefaultConfig()           // AllowPrivateIPs=false
	cfg.AllowNonStandardPorts = true // isolate the dial-time IP policy from the port gate
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

func TestResolveRedirectToNonStandardPortBlockedBeforeSecondDial(t *testing.T) {
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://target.test:8080/media.png", http.StatusFound)
	}))
	defer redirect.Close()
	redirectAddr := strings.TrimPrefix(redirect.URL, "http://")

	cfg := DefaultConfig() // standard ports only
	r := NewResolver(cfg, nil)
	var targetDials int32
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			switch address {
			case "origin.test:80":
				return (&net.Dialer{}).DialContext(ctx, network, redirectAddr)
			case "target.test:8080":
				atomic.AddInt32(&targetDials, 1)
			}
			return nil, net.UnknownNetworkError(address)
		},
	}
	r.client = &http.Client{Transport: transport, CheckRedirect: redirectGuard(cfg)}

	mustErr(t, chatBody(imagePartObj("http://origin.test/start")), r, http.StatusForbidden, "media_blocked")
	if n := atomic.LoadInt32(&targetDials); n != 0 {
		t.Fatalf("redirect to non-standard port was dialed %d time(s); must be rejected first", n)
	}
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

func TestHasRemoteMediaAndRemoteMediaURLs(t *testing.T) {
	withRemote := chatBody(imagePartObj("https://example.com/a.png"), videoPartObj("https://example.com/v.mp4"))
	if !HasRemoteMedia(withRemote) {
		t.Error("HasRemoteMedia = false for a remote image_url")
	}
	urls := RemoteMediaURLs(withRemote)
	if !urls["https://example.com/a.png"] || !urls["https://example.com/v.mp4"] || len(urls) != 2 {
		t.Errorf("RemoteMediaURLs = %v, want both remote refs", urls)
	}
	withData := chatBody(imagePartObj("data:image/png;base64,iVBORw0KGgo="))
	if HasRemoteMedia(withData) {
		t.Error("HasRemoteMedia = true for an inline data: URI")
	}
	if RemoteMediaURLs(withData) != nil {
		t.Error("RemoteMediaURLs must be nil for inline-only bodies")
	}
	textOnly := map[string]any{"messages": []any{map[string]any{"role": "user", "content": "hi"}}}
	if HasRemoteMedia(textOnly) {
		t.Error("HasRemoteMedia = true for a text-only request")
	}
	// Anthropic source blocks are NOT fetchable shapes — must not be collected.
	anthropic := chatBody(map[string]any{
		"type":   "image",
		"source": map[string]any{"type": "url", "url": "https://example.com/anthropic.png"},
	})
	if HasRemoteMedia(anthropic) {
		t.Error("Anthropic source blocks must not be collected as fetchable")
	}
}

// jsonRoundTrip guards that a resolved body re-marshals to valid JSON the
// downstream encrypt path can forward.
func TestResolvedBodyReMarshals(t *testing.T) {
	srv := serveBytes(validPNG(t))
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

func TestConfigSanitized(t *testing.T) {
	c := Config{Enabled: true, MaxFileBytes: 64 << 20, MaxTotalBytes: 1 << 20}.sanitized()
	if c.MaxFileBytes != c.MaxTotalBytes {
		t.Errorf("per-file cap must clamp DOWN to the total budget; got file=%d total=%d", c.MaxFileBytes, c.MaxTotalBytes)
	}
	c = Config{}.sanitized()
	if c.MaxParts <= 0 || c.FetchTimeout <= 0 || c.TotalDeadline <= 0 || c.Concurrency <= 0 ||
		c.GlobalConcurrency <= 0 || c.MaxFileBytes <= 0 || c.MaxTotalBytes <= 0 {
		t.Errorf("zero config must clamp to safe defaults: %+v", c)
	}
	if c.MaxImageMegapixels != 0 {
		t.Errorf("MaxImageMegapixels=0 is a meaningful off switch, must not be clamped; got %d", c.MaxImageMegapixels)
	}
	if (Config{MaxImageMegapixels: -5}).sanitized().MaxImageMegapixels != DefaultMaxImageMegapixels {
		t.Error("negative MaxImageMegapixels must clamp to the default")
	}
}

func TestConfigFromEnvNonStandardPortOverride(t *testing.T) {
	t.Setenv(envAllowOtherPorts, "true")
	if !ConfigFromEnv().AllowNonStandardPorts {
		t.Error("explicit non-standard-port dev/test override was not read")
	}
}
