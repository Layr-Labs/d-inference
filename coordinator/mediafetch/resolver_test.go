package mediafetch

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
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

func TestResolvePreservesClientCancellation(t *testing.T) {
	r := NewResolver(DefaultConfig(), nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := r.Resolve(ctx, chatBody(imagePartObj("https://example.com/cancelled.png")))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Resolve error = %v, want context.Canceled", err)
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

func TestResolveDuplicateURLFetchesOnce(t *testing.T) {
	img := validPNG(t)
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(img)
	}))
	defer srv.Close()

	r := NewResolver(devConfig(), nil)
	parsed := chatBody(
		imagePartObj(srv.URL+"/same.png#first"),
		imagePartStr("  "+srv.URL+"/same.png#second  "),
		imagePartObj(srv.URL+"/same.png"),
	)
	res, err := r.Resolve(context.Background(), parsed)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if res.Count != 1 || res.Bytes != int64(len(img)) || atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("Count=%d Bytes=%d hits=%d, want 1/%d/1", res.Count, res.Bytes, hits, len(img))
	}
	want := firstImageURL(t, parsed, 0)
	for i := 0; i < 3; i++ {
		if got := firstImageURL(t, parsed, i); got != want || !strings.HasPrefix(got, "data:image/png;base64,") {
			t.Errorf("part %d = %.40q, want shared inlined data URI", i, got)
		}
	}
}

func TestResolveDuplicateTargetsStillRespectPartCap(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(validPNG(t))
	}))
	defer srv.Close()

	cfg := devConfig()
	cfg.MaxParts = 2
	r := NewResolver(cfg, nil)
	parsed := chatBody(
		imagePartObj(srv.URL+"/same.png#one"),
		imagePartObj(srv.URL+"/same.png#two"),
		imagePartObj(srv.URL+"/same.png#three"),
	)
	mustErr(t, parsed, r, http.StatusBadRequest, "too_many_media_parts")
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("over-limit duplicate targets triggered %d fetch(es); want 0", n)
	}
}

func TestResolveSameURLWithConflictingKindsRejectsBeforeFetch(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(validPNG(t))
	}))
	defer srv.Close()

	r := NewResolver(devConfig(), nil)
	parsed := chatBody(imagePartObj(srv.URL+"/same#image"), videoPartObj(srv.URL+"/same#video"))
	mustErr(t, parsed, r, http.StatusBadRequest, "media_kind_mismatch")
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("conflicting kinds triggered %d fetch(es); want 0", n)
	}
}

// TestGroupMediaRefsDedupKey pins what the dedup key does and — more importantly
// — what it must NOT do. The key normalizes only what can never change the
// on-the-wire target (scheme/host case, fragment). It must never rewrite the URL
// that is actually fetched: an explicitly written :80/:443 stays, because a
// presigned S3/R2/GCS signature can cover the exact host:port and stripping it
// turns a valid link into an upstream auth error.
func TestGroupMediaRefsDedupKey(t *testing.T) {
	// Case and fragment differ only off the wire → one fetch, two targets, and
	// the URL requested is the first ORIGINAL string, not a normalized rewrite.
	original := "HTTPS://Example.COM/a.png#one"
	fetches, err := groupMediaRefs([]mediaRef{
		{url: original, kind: kindImage},
		{url: "https://example.com/a.png#two", kind: kindImage},
	})
	if err != nil {
		t.Fatalf("groupMediaRefs: %v", err)
	}
	if len(fetches) != 1 || len(fetches[0].targets) != 2 {
		t.Fatalf("case/fragment variants = %+v, want one group with two targets", fetches)
	}
	if fetches[0].request.url != original {
		t.Errorf("fetched URL = %q, want the consumer's original %q — the key must not rewrite it",
			fetches[0].request.url, original)
	}

	// An explicit default port is NOT folded away: two fetches, each requesting
	// exactly what the consumer wrote.
	fetches, err = groupMediaRefs([]mediaRef{
		{url: "https://example.com:443/a.png", kind: kindImage},
		{url: "https://example.com/a.png", kind: kindImage},
	})
	if err != nil {
		t.Fatalf("groupMediaRefs: %v", err)
	}
	if len(fetches) != 2 {
		t.Fatalf("explicit :443 grouped with the portless form (%+v); a signed host:port must be preserved", fetches)
	}
	if fetches[0].request.url != "https://example.com:443/a.png" {
		t.Errorf("fetched URL = %q, want the explicit port preserved", fetches[0].request.url)
	}

	// IPv6 hex digits are case-insensitive, so they share one fetch.
	fetches, err = groupMediaRefs([]mediaRef{
		{url: "https://[2001:DB8::1]/a.png", kind: kindImage},
		{url: "https://[2001:db8::1]/a.png", kind: kindImage},
	})
	if err != nil {
		t.Fatalf("groupMediaRefs: %v", err)
	}
	if len(fetches) != 1 || len(fetches[0].targets) != 2 {
		t.Fatalf("IPv6 case variants = %+v, want one group with two targets", fetches)
	}

	// Query strings are application-semantic and must remain distinct.
	fetches, err = groupMediaRefs([]mediaRef{
		{url: "https://example.com/a.png?v=1", kind: kindImage},
		{url: "https://example.com/a.png?v=2", kind: kindImage},
	})
	if err != nil || len(fetches) != 2 {
		t.Fatalf("query-distinct groups = %d, err=%v; want 2", len(fetches), err)
	}
}

func mustErr(t *testing.T, parsed map[string]any, r *Resolver, wantStatus int, wantCode string) {
	t.Helper()
	mustErrDetail(t, parsed, r, wantStatus, wantCode)
}

// mustErrDetail is mustErr, returning the typed error so a caller can pin WHICH
// guard rejected the request: several mechanisms share one status/code pair and
// only the Internal diagnostic distinguishes them.
func mustErrDetail(t *testing.T, parsed map[string]any, r *Resolver, wantStatus int, wantCode string) *Error {
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
	return me
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

func TestResolveRedirectStripsRefererToPreventSignedURLLeak(t *testing.T) {
	img := validPNG(t)
	var gotReferer string
	var sawSecond int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&sawSecond, 1)
		gotReferer = r.Header.Get("Referer")
		w.Write(img)
	}))
	defer target.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/real.png", http.StatusFound)
	}))
	defer origin.Close()

	r := NewResolver(devConfig(), nil)
	// A presigned-style signature in the query must not reach the redirect target.
	parsed := chatBody(imagePartObj(origin.URL + "/signed.png?X-Amz-Signature=leak-me"))
	if _, err := r.Resolve(context.Background(), parsed); err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if atomic.LoadInt32(&sawSecond) != 1 {
		t.Fatalf("redirect target hit %d time(s), want 1", sawSecond)
	}
	if gotReferer != "" {
		t.Errorf("redirect target saw Referer %q; signed origin URL must not leak", gotReferer)
	}
}

func TestHasRemoteMediaAndFetchablePart(t *testing.T) {
	withRemote := chatBody(imagePartObj("https://example.com/a.png"), videoPartObj("https://example.com/v.mp4"))
	if !HasRemoteMedia(withRemote) {
		t.Error("HasRemoteMedia = false for a remote image_url")
	}
	parts := withRemote["messages"].([]any)[0].(map[string]any)["content"].([]any)
	for i, part := range parts {
		if !IsFetchableRemotePart(part.(map[string]any)) {
			t.Errorf("part %d must be fetchable", i)
		}
	}
	withData := chatBody(imagePartObj("data:image/png;base64,iVBORw0KGgo="))
	if HasRemoteMedia(withData) {
		t.Error("HasRemoteMedia = true for an inline data: URI")
	}
	inlinePart := withData["messages"].([]any)[0].(map[string]any)["content"].([]any)[0].(map[string]any)
	if IsFetchableRemotePart(inlinePart) {
		t.Error("inline data URI must not be classified as a fetchable remote part")
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
	if IsFetchableRemotePart(anthropic["messages"].([]any)[0].(map[string]any)["content"].([]any)[0].(map[string]any)) {
		t.Error("Anthropic source block must not be classified as fetchable")
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
		c.GlobalConcurrency <= 0 || c.MaxFileBytes <= 0 || c.MaxTotalBytes <= 0 || c.MaxInlinedBytes <= 0 {
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

// TestResolverEnabledIsConstructionTime pins that the kill switch is the value
// captured when the Resolver was built, and that ConfigFromEnv is what reads the
// env. An earlier revision called env.EnvBool on every Enabled() call and
// advertised the switch as redeploy-free — a false promise, because os.Getenv
// returns the process environment captured at exec, so editing the env file or
// reloading the unit cannot change a running coordinator. Re-adding a per-call
// env read would restore the overhead and the wrong operational expectation.
func TestResolverEnabledIsConstructionTime(t *testing.T) {
	cfg := devConfig()
	cfg.Enabled = true
	r := NewResolver(cfg, nil)
	if !r.Enabled() {
		t.Fatal("Enabled() must report the Config value it was built with")
	}

	// Changing the environment underneath a live Resolver must NOT change it:
	// the process env of a running coordinator cannot be edited from outside
	// either, so pretending otherwise is the bug this guards.
	t.Setenv(envEnabled, "false")
	if !r.Enabled() {
		t.Error("Enabled() re-read the environment; it must reflect construction time only")
	}

	// The switch takes effect through ConfigFromEnv at construction, which is
	// what a process restart actually re-runs.
	if NewResolver(ConfigFromEnv(), nil).Enabled() {
		t.Error("a Resolver built after ENABLED=false must be disabled")
	}
}

// TestNewResolverWarnsOnSSRFOverride pins the boot warning for the two dev-only
// escape hatches. Config.Check deliberately accepts them (single-host
// deployments need them), so this WARN is the only signal an operator gets that
// a process is running without the full SSRF policy.
func TestNewResolverWarnsOnSSRFOverride(t *testing.T) {
	cases := []struct {
		name          string
		privateIPs    bool
		otherPorts    bool
		wantWarn      bool
		wantSubstring []string
	}{
		{"production defaults stay quiet", false, false, false, nil},
		{"private IPs", true, false, true, []string{"allow_private_ips=true", "allow_nonstandard_ports=false"}},
		{"nonstandard ports", false, true, true, []string{"allow_private_ips=false", "allow_nonstandard_ports=true"}},
		{"both", true, true, true, []string{"allow_private_ips=true", "allow_nonstandard_ports=true"}},
	}
	for _, c := range cases {
		buf := &bytes.Buffer{}
		cfg := DefaultConfig()
		cfg.AllowPrivateIPs = c.privateIPs
		cfg.AllowNonStandardPorts = c.otherPorts
		NewResolver(cfg, slog.New(slog.NewTextHandler(buf, nil)))

		got := strings.Contains(buf.String(), "media fetch SSRF override enabled")
		if got != c.wantWarn {
			t.Errorf("%s: warned = %v, want %v (log: %s)", c.name, got, c.wantWarn, buf.String())
			continue
		}
		for _, want := range c.wantSubstring {
			if !strings.Contains(buf.String(), want) {
				t.Errorf("%s: warning must carry %s; got %s", c.name, want, buf.String())
			}
		}
	}
}

// gzipBytes returns data compressed with gzip.
func gzipBytes(t *testing.T, data []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(data); err != nil {
		t.Fatalf("gzip write: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("gzip close: %v", err)
	}
	return buf.Bytes()
}

// TestResolveGzipEncodedBodyIsNotInflated is the behavioral half of the
// no-transparent-decompression guarantee: a hostile origin declares
// Content-Encoding: gzip over a payload that would inflate into a perfectly
// valid PNG. The coordinator must hand the RAW gzip bytes to the magic-byte
// sniffer — which rejects them — instead of inflating an attacker-controlled
// stream whose expanded size is not bounded by the read caps. It also pins the
// request-side half of the guard (Accept-Encoding: identity).
func TestResolveGzipEncodedBodyIsNotInflated(t *testing.T) {
	inner := validPNG(t)
	var sawAcceptEncoding atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAcceptEncoding.Store(r.Header.Get("Accept-Encoding"))
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Content-Type", "image/png")
		w.Write(gzipBytes(t, inner))
	}))
	defer srv.Close()

	r := NewResolver(devConfig(), nil)
	mustErr(t, chatBody(imagePartObj(srv.URL+"/bomb.png")), r, http.StatusBadRequest, "media_invalid_type")

	if ae, _ := sawAcceptEncoding.Load().(string); ae != "identity" {
		t.Errorf("outbound Accept-Encoding = %q, want \"identity\" — the request must never advertise a compressed encoding", ae)
	}
}

// TestHTTPClientDisableCompression pins Transport.DisableCompression itself.
// fetchOne ALSO sends "Accept-Encoding: identity", and either guard alone stops
// Go's transparent inflation — Transport only auto-inflates a response when IT
// added the Accept-Encoding header — so an end-to-end fetch can never tell which
// of the two is load-bearing. Driving the client directly with no request-level
// Accept-Encoding isolates the transport setting: flipping DisableCompression to
// false makes Go advertise gzip, inflate the response, and hand back the PNG the
// bomb was hiding.
func TestHTTPClientDisableCompression(t *testing.T) {
	inner := validPNG(t)
	compressed := gzipBytes(t, inner)
	var advertised atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		advertised.Store(r.Header.Get("Accept-Encoding"))
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Content-Type", "image/png")
		w.Write(compressed)
	}))
	defer srv.Close()

	resp, err := newHTTPClient(devConfig()).Get(srv.URL + "/bomb.png")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}

	if ae, _ := advertised.Load().(string); ae != "" {
		t.Errorf("transport advertised Accept-Encoding %q; DisableCompression must stop it from requesting gzip", ae)
	}
	if resp.Uncompressed {
		t.Error("response was transparently inflated; DisableCompression must keep the body raw")
	}
	if !bytes.Equal(body, compressed) {
		t.Errorf("body was rewritten by the transport (%d bytes, want the %d raw gzip bytes)", len(body), len(compressed))
	}
	if bytes.Equal(body, inner) {
		t.Error("transport inflated the gzip bomb back into a valid PNG — a decompressed stream would bypass the read caps")
	}
}

// TestHTTPClientPerHostCapIsProcessWideNotPerRequest pins MaxConnsPerHost to
// GlobalConcurrency. The client is built ONCE per Resolver, so MaxConnsPerHost
// is a process-wide bound on concurrent sockets to a single origin — and with
// DisableKeepAlives no connection is ever reused, so a cap of Concurrency (the
// per-REQUEST worker-pool size, 4) forces all media traffic to one CDN into
// serialized waves of four. That queue wait is charged against FetchTimeout, so
// a healthy origin starts returning spurious media_fetch_timeout under load.
//
// The origin here blocks every request until `want` of them are simultaneously
// in flight. Reverting MaxConnsPerHost to cfg.Concurrency caps the observed peak
// at 4, the barrier never opens, and the test fails.
func TestHTTPClientPerHostCapIsProcessWideNotPerRequest(t *testing.T) {
	cfg := devConfig()
	const want = 8 // > cfg.Concurrency (4), <= cfg.GlobalConcurrency (32)
	if want <= cfg.Concurrency || want > cfg.GlobalConcurrency {
		t.Fatalf("test premise broken: want=%d must sit between Concurrency=%d and GlobalConcurrency=%d",
			want, cfg.Concurrency, cfg.GlobalConcurrency)
	}

	var inFlight, peak atomic.Int32
	allArrived := make(chan struct{})
	var once sync.Once
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := inFlight.Add(1)
		defer inFlight.Add(-1)
		for {
			old := peak.Load()
			if n <= old || peak.CompareAndSwap(old, n) {
				break
			}
		}
		if n >= want {
			once.Do(func() { close(allArrived) })
		}
		select {
		case <-allArrived:
		case <-time.After(3 * time.Second): // capped so a regression fails instead of hanging
		}
		w.Write([]byte("ok"))
	}))
	defer srv.Close()

	client := newHTTPClient(cfg)
	var wg sync.WaitGroup
	for range want {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := client.Get(srv.URL + "/media.png")
			if err != nil {
				t.Errorf("GET: %v", err)
				return
			}
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}()
	}
	wg.Wait()

	if got := peak.Load(); got != want {
		t.Errorf("peak concurrent sockets to one origin = %d, want %d; MaxConnsPerHost must be the process-wide GlobalConcurrency, not the per-request Concurrency", got, want)
	}
}

// --- fetch-worker panic containment ----------------------------------------

// panicRoundTripper stands in for a panic anywhere on the fetch path. Every
// step below fetchAll's `go func` — the outbound HTTP/TLS client, the sniffer,
// jpeg/png/gif.DecodeConfig, the hand-rolled WebP/BMP header parsers — runs
// over attacker-chosen bytes on that spawned goroutine.
type panicRoundTripper struct{}

func (panicRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	panic("mediafetch test: synthetic panic on the fetch path")
}

// A panic on a goroutine SPAWNED inside an http.Handler is a runtime fatal:
// net/http recovers panics only on the per-connection handler goroutine, so an
// unrecovered panic here kills the process and every in-flight request from
// every consumer. The worker must recover through saferun (stack trace + panic
// metric) and turn the aborted fetch into a typed error, never leave out[i] nil
// for Resolve to dereference.
func TestResolveRecoversPanicInFetchWorker(t *testing.T) {
	var (
		mu       sync.Mutex
		observed []string
	)
	saferun.SetPanicObserver(func(name string) {
		mu.Lock()
		observed = append(observed, name)
		mu.Unlock()
	})
	t.Cleanup(func() { saferun.SetPanicObserver(nil) })

	r := NewResolver(devConfig(), nil)
	r.client.Transport = panicRoundTripper{}

	const url0 = "http://media.test/a.png"
	parsed := chatBody(imagePartObj(url0), imagePartObj("http://media.test/b.png"))

	mustErr(t, parsed, r, http.StatusBadGateway, "media_fetch_failed")

	if got := firstImageURL(t, parsed, 0); got != url0 {
		t.Errorf("a panicking fetch mutated the request: part 0 = %.40q", got)
	}
	mu.Lock()
	seen := append([]string(nil), observed...)
	mu.Unlock()
	if len(seen) == 0 {
		t.Error("panic was not routed through saferun.Recover: no observer callback fired, " +
			"so operators get neither the stack trace nor the panic metric")
	}
	for _, name := range seen {
		if name != "mediafetch.fetchOne" {
			t.Errorf("panic observer got goroutine %q, want mediafetch.fetchOne", name)
		}
	}
	if stuck := fetchWorkersRunning(); stuck > 0 {
		t.Errorf("%d fetch worker goroutine(s) still running after a recovered panic", stuck)
	}
	// The recovery must unwind through the semaphore releases too: a slot held
	// by a dead worker would wedge every future fetch in the process.
	if held := len(r.globalSem); held != 0 {
		t.Errorf("global fetch semaphore still holds %d slot(s) after a recovered panic", held)
	}
}

// fetchWorkersRunning counts the mediafetch fetch workers still on the stack,
// polling briefly so a worker mid-unwind isn't reported as stuck. Unrelated
// goroutines are ignored — notably net/http's own Client.Timeout watcher, which
// the stdlib strands when a RoundTripper panics.
func fetchWorkersRunning() int {
	var running int
	for range 50 {
		if running = countGoroutineFrames("(*Resolver).fetchAll"); running == 0 {
			return 0
		}
		time.Sleep(10 * time.Millisecond)
	}
	return running
}

// countGoroutineFrames reports how many frames in the all-goroutine stack dump
// mention fn.
func countGoroutineFrames(fn string) int {
	buf := make([]byte, 1<<16)
	for {
		if n := runtime.Stack(buf, true); n < len(buf) {
			return strings.Count(string(buf[:n]), fn)
		}
		buf = make([]byte, 2*len(buf))
	}
}

// --- post-inline projection -------------------------------------------------

// A URL repeated across parts is fetched ONCE but written back to every
// location, so N targets inline N copies of the same base64 blob. MaxFileBytes
// and MaxTotalBytes bound only what is fetched and cannot see that
// multiplication; MaxInlinedBytes must reject it before anything is mutated,
// instead of letting the coordinator build a body the API layer can only throw
// away afterwards.
func TestResolveDuplicateTargetsRejectedByInlinedProjection(t *testing.T) {
	img := validPNG(t)
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(img)
	}))
	defer srv.Close()

	cfg := devConfig()
	// One fetch, far inside every byte cap; eight targets inline 8x its data URI.
	cfg.MaxInlinedBytes = 4 * int64(len(toDataURI(&fetchedMedia{mime: "image/png", data: img})))
	r := NewResolver(cfg, nil)

	urls := make([]string, DefaultMaxParts) // exactly at MaxParts: the part cap cannot catch this
	parts := make([]map[string]any, len(urls))
	for i := range urls {
		urls[i] = fmt.Sprintf("%s/same.png#%d", srv.URL, i)
		parts[i] = imagePartObj(urls[i])
	}
	parsed := chatBody(parts...)

	me := mustErrDetail(t, parsed, r, http.StatusRequestEntityTooLarge, "media_too_large")
	if !strings.Contains(me.Internal, "projected inlined") {
		t.Errorf("rejected by %q; want the post-inline projection, not a raw byte cap", me.Internal)
	}
	for i := range urls {
		if got := firstImageURL(t, parsed, i); got != urls[i] {
			t.Errorf("part %d = %.40q; a rejected resolve must inline nothing", i, got)
		}
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Errorf("origin hits = %d, want 1: the shared URL is fetched once and duplicated", n)
	}
}

// --- budget / concurrency / deadline wiring ---------------------------------

// The shared byte budget must cut CONCURRENT reads off mid-stream. fetchAll's
// post-hoc aggregate check cannot do that job: it only runs once a fetch has
// been fully buffered, so Concurrency x MaxFileBytes can be retained before it
// notices. Here each body fits MaxFileBytes and only the overlap breaches
// MaxTotalBytes, so at most ONE fetch can ever complete — the post-hoc check can
// never fire, and only fetchOne's totalBudget.reader can reject this.
func TestResolveSharedReadBudgetInterruptsConcurrentReads(t *testing.T) {
	const (
		parts     = 4
		bodySize  = 256 << 10
		chunkSize = 8 << 10
	)
	// MP4 (not PNG): a body that does complete must pass content validation, so
	// the read-time budget stays the only possible source of the error.
	body := mp4Bytes(bodySize)
	var written int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, _ := w.(http.Flusher)
		for sent := 0; sent < len(body); sent += chunkSize {
			n, err := w.Write(body[sent:min(sent+chunkSize, len(body))])
			atomic.AddInt64(&written, int64(n))
			if err != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
			// Pace delivery so the four reads genuinely overlap rather than each
			// response landing whole in a socket buffer.
			select {
			case <-r.Context().Done():
				return
			case <-time.After(2 * time.Millisecond):
			}
		}
	}))
	defer srv.Close()

	cfg := devConfig()
	cfg.Concurrency = parts
	cfg.MaxFileBytes = bodySize + (32 << 10)  // each body on its own is fine ...
	cfg.MaxTotalBytes = bodySize + (64 << 10) // ... but no two of them fit together
	r := NewResolver(cfg, nil)

	items := make([]map[string]any, parts)
	for i := range items {
		items[i] = videoPartObj(fmt.Sprintf("%s/stream-%d.mp4", srv.URL, i))
	}
	me := mustErrDetail(t, chatBody(items...), r, http.StatusRequestEntityTooLarge, "media_too_large")
	if !strings.Contains(me.Internal, "aggregate body exceeded cap") {
		t.Errorf("rejected by %q; want the read-time shared budget (fetchOne's totalBudget.reader), "+
			"not fetchAll's post-hoc backstop", me.Internal)
	}
	if got, full := atomic.LoadInt64(&written), int64(parts*bodySize); got >= full {
		t.Errorf("origins delivered %d of %d bytes: the shared budget must stop the reads mid-stream, "+
			"never buffer the whole aggregate", got, full)
	}
}

// The process-wide semaphore bounds in-flight fetches across ALL requests: it
// is the only thing stopping a burst of media-heavy requests from opening an
// unbounded number of outbound sockets. Two ORIGINS are used deliberately —
// Transport.MaxConnsPerHost is also derived from GlobalConcurrency but is keyed
// per host, so only the semaphore can serialize fetches that target different
// hosts from different requests.
func TestResolveGlobalConcurrencyBoundsFetchesAcrossRequests(t *testing.T) {
	img := validPNG(t)
	var inFlight, peak atomic.Int64
	origin := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cur := inFlight.Add(1)
		for {
			old := peak.Load()
			if cur <= old || peak.CompareAndSwap(old, cur) {
				break
			}
		}
		time.Sleep(40 * time.Millisecond) // hold the slot long enough for overlap to be observable
		w.Write(img)
		inFlight.Add(-1)
	})
	hosts := []*httptest.Server{httptest.NewServer(origin), httptest.NewServer(origin)}
	for _, srv := range hosts {
		defer srv.Close()
	}

	cfg := devConfig()
	cfg.GlobalConcurrency = 1
	cfg.Concurrency = 4 // the per-request worker cap must not be what bounds this
	r := NewResolver(cfg, nil)

	var wg sync.WaitGroup
	errs := make([]error, 2)
	for req := range errs {
		wg.Add(1)
		go func(req int) {
			defer wg.Done()
			_, errs[req] = r.Resolve(context.Background(), chatBody(
				imagePartObj(fmt.Sprintf("%s/r%d.png", hosts[0].URL, req)),
				imagePartObj(fmt.Sprintf("%s/r%d.png", hosts[1].URL, req)),
			))
		}(req)
	}
	wg.Wait()

	for req, err := range errs {
		if err != nil {
			t.Fatalf("Resolve %d: %v", req, err)
		}
	}
	if got := peak.Load(); got > 1 {
		t.Errorf("peak concurrent fetches = %d with GlobalConcurrency=1; the process-wide semaphore "+
			"must bound in-flight fetches across requests and hosts", got)
	}
}

// TotalDeadline bounds the WHOLE resolution step. FetchTimeout is deliberately
// far longer here, so a fetch that outlives the step budget can only be stopped
// by the total deadline: without it this request simply succeeds, slowly.
func TestResolveTotalDeadlineBoundsWholeStep(t *testing.T) {
	img := validPNG(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(400 * time.Millisecond):
			w.Write(img)
		case <-r.Context().Done(): // the client gave up; don't hold Close()
		}
	}))
	defer srv.Close()

	cfg := devConfig()
	cfg.TotalDeadline = 60 * time.Millisecond
	cfg.FetchTimeout = 30 * time.Second
	r := NewResolver(cfg, nil)

	start := time.Now()
	mustErr(t, chatBody(imagePartObj(srv.URL+"/slow.png")), r, http.StatusRequestTimeout, "media_fetch_timeout")
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("resolve took %v: the whole-step TotalDeadline (%v) must bound it, not FetchTimeout (%v)",
			elapsed, cfg.TotalDeadline, cfg.FetchTimeout)
	}
}

// TestResolveRejectsHTTPSToHTTPDowngrade pins that an https caller keeps
// transport confidentiality across the whole redirect chain. Validating each hop
// independently against the scheme allowlist accepts the downgrade — both
// schemes are individually legal — but it puts a redirect's signed query on the
// wire in plaintext and lets an on-path party swap the bytes before they are
// inlined into the (encrypted) provider request.
func TestResolveRejectsHTTPSToHTTPDowngrade(t *testing.T) {
	var plainHits int32
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&plainHits, 1)
		w.Write(validPNG(t))
	}))
	defer plain.Close()

	tls := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, plain.URL+"/downgraded.png", http.StatusFound)
	}))
	defer tls.Close()

	cfg := devConfig()
	r := NewResolver(cfg, nil)
	// Trust the httptest CA so the first (https) hop succeeds and the downgrade
	// is the only thing under test.
	r.client.Transport.(*http.Transport).TLSClientConfig = tls.Client().Transport.(*http.Transport).TLSClientConfig

	mustErr(t, chatBody(imagePartObj(tls.URL+"/redir")), r, http.StatusBadRequest, "media_invalid_scheme")
	if n := atomic.LoadInt32(&plainHits); n != 0 {
		t.Errorf("downgraded hop was dialed %d time(s); the guard must refuse before the request", n)
	}
}

// TestMediaTransportCapsResponseHeaders pins the header budget. Headers are read
// before any body cap applies and Go's default is 10 MiB per connection, so an
// attacker-controlled origin could force GlobalConcurrency x 10 MiB of buffering
// while every body stayed within budget.
func TestMediaTransportCapsResponseHeaders(t *testing.T) {
	c := newHTTPClient(DefaultConfig())
	tr, ok := c.Transport.(*http.Transport)
	if !ok {
		t.Fatal("media client transport is not *http.Transport")
	}
	if tr.MaxResponseHeaderBytes <= 0 || tr.MaxResponseHeaderBytes > 1<<20 {
		t.Errorf("MaxResponseHeaderBytes = %d, want a small explicit cap (0 means Go's 10 MiB default)",
			tr.MaxResponseHeaderBytes)
	}
}
