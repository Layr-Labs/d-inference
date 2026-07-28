package api

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// --- helpers ----------------------------------------------------------------

// testPNG returns a real, decodable 2x2 PNG (passes both the sniff allowlist
// and the header pixel gate).
func testPNG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

// pngHandler serves a valid PNG and counts hits (for fetched/not-fetched asserts).
func pngHandler(t *testing.T, hits *int32) http.HandlerFunc {
	img := testPNG(t)
	return func(w http.ResponseWriter, r *http.Request) {
		if hits != nil {
			atomic.AddInt32(hits, 1)
		}
		w.Write(img)
	}
}

// makeVisionRoutableProvider registers an online, routable, vision-capable
// provider for model so a media request clears visionToolsFailFast and reaches
// the remote-media gate/resolution steps the HTTP-path tests below exercise.
// Nil test catalog => IsModelInCatalog/HasVisionProviderForModel allow it.
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

// minimalMediaServer builds a Server with only the fields the media gate /
// resolver bridge touch, using a resolver that permits loopback so httptest
// works.
func minimalMediaServer(cfg mediafetch.Config) *Server {
	return &Server{
		logger:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		mediaResolver: mediafetch.NewResolver(cfg, nil),
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

func sealedReq() *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	return req.WithContext(context.WithValue(req.Context(), sealedCtxKey, struct{}{}))
}

func plainReq() *http.Request {
	return httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
}

func testMeta() mediaResolveMeta {
	return mediaResolveMeta{model: "test", publicModel: "test"}
}

// --- resolveRemoteMedia (phase 2, post-reservation) --------------------------

func TestResolveRemoteMediaInlinesOnSuccess(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	s := minimalMediaServer(cfg)

	media := httptest.NewServer(pngHandler(t, nil))
	defer media.Close()

	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	w := httptest.NewRecorder()
	timing := &registry.RequestTiming{}

	out, inlined, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, timing, testMeta())
	if !ok {
		t.Fatalf("resolveRemoteMedia ok=false, body=%s", w.Body.String())
	}
	if !inlined {
		t.Error("a body whose remote URL was inlined must report inlined=true")
	}
	if !bytes.Contains(out, []byte("data:image/png;base64,")) {
		t.Errorf("returned body not inlined: %.80s", out)
	}
	if bytes.Contains(out, []byte("http://")) {
		t.Errorf("returned body still carries an http URL: %.120s", out)
	}
	if timing.MediaFetchedAt.IsZero() {
		t.Error("MediaFetchedAt must be stamped when media was fetched (X-Timing media_fetch_us)")
	}
}

func TestResolveRemoteMediaNoRemoteNoOp(t *testing.T) {
	s := minimalMediaServer(mediafetch.DefaultConfig())
	raw, parsed := chatBodyBytes(t, "data:image/png;base64,iVBORw0KGgo=")
	w := httptest.NewRecorder()
	timing := &registry.RequestTiming{}

	out, inlined, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, timing, testMeta())
	if !ok || inlined || !bytes.Equal(out, raw) {
		t.Fatalf("inline-only body must pass through unchanged (ok=%v inlined=%v)", ok, inlined)
	}
	if !timing.MediaFetchedAt.IsZero() {
		t.Error("MediaFetchedAt must stay zero when nothing was fetched")
	}
}

func TestResolveRemoteMediaNilResolverPassthrough(t *testing.T) {
	s := &Server{logger: quietLogger()} // e.g. a bare test Server
	raw, parsed := chatBodyBytes(t, "https://example.com/cat.png")
	w := httptest.NewRecorder()

	out, inlined, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, testMeta())
	if !ok || inlined || !bytes.Equal(out, raw) {
		t.Fatal("nil resolver must behave as disabled passthrough")
	}
}

func TestResolveRemoteMediaClientCancellationWritesNoRejection(t *testing.T) {
	s := minimalMediaServer(mediafetch.DefaultConfig())
	raw, parsed := chatBodyBytes(t, "https://example.com/cancelled.png")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := plainReq().WithContext(ctx)
	w := httptest.NewRecorder()

	out, _, ok := s.resolveRemoteMedia(w, req, raw, parsed, &registry.RequestTiming{}, testMeta())
	if ok || out != nil {
		t.Fatal("client cancellation must stop resolution")
	}
	if w.Body.Len() != 0 {
		t.Fatalf("client cancellation wrote a rejection body: %s", w.Body.String())
	}
}

func TestResolveRemoteMediaFailureWrites400(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	s := minimalMediaServer(cfg)

	// Origin serves HTML behind a lying image Content-Type header.
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Write([]byte("<!DOCTYPE html><html>not an image</html>"))
	}))
	defer media.Close()

	raw, parsed := chatBodyBytes(t, media.URL+"/fake.png")
	w := httptest.NewRecorder()

	out, _, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, testMeta())
	if ok || out != nil {
		t.Fatal("invalid content must fail the request")
	}
	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
	if code := errType(t, w.Body.Bytes()); code != "media_invalid_type" {
		t.Errorf("error code = %q, want media_invalid_type", code)
	}
	// The consumer-facing message must not echo the internal origin host.
	if strings.Contains(w.Body.String(), "127.0.0.1") {
		t.Errorf("error body leaks the origin host: %s", w.Body.String())
	}
}

func TestResolveRemoteMediaNeverLogsPresignedURLSecrets(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))
	s := &Server{logger: logger, mediaResolver: mediafetch.NewResolver(cfg, logger)}

	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "missing", http.StatusNotFound)
	}))
	defer media.Close()
	const secret = "X-Amz-Signature=do-not-log-this-secret"
	raw, parsed := chatBodyBytes(t, media.URL+"/private.png?"+secret)
	w := httptest.NewRecorder()

	if out, _, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, testMeta()); ok || out != nil {
		t.Fatal("upstream 404 must fail media resolution")
	}
	if got := logs.String(); strings.Contains(got, secret) || strings.Contains(got, media.URL) || strings.Contains(got, "/private.png") {
		t.Fatalf("logs contain request URL or secret: %s", got)
	}
}

// --- gateRemoteMediaPreDispatch (phase 1, pre-billing) -----------------------

func TestGateSealedRejectsRemoteWithoutFetching(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	s := minimalMediaServer(cfg)

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	_, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	w := httptest.NewRecorder()

	if !s.gateRemoteMediaPreDispatch(w, sealedReq(), parsed, "test", "test", true, false) {
		t.Fatal("sealed request with a remote URL must be handled (rejected)")
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

func TestGateSealedAllowsInlineData(t *testing.T) {
	s := minimalMediaServer(mediafetch.DefaultConfig())
	_, parsed := chatBodyBytes(t, "data:image/png;base64,iVBORw0KGgo=")
	w := httptest.NewRecorder()
	if s.gateRemoteMediaPreDispatch(w, sealedReq(), parsed, "test", "test", true, false) {
		t.Fatal("sealed request with inline data: must pass the gate")
	}
}

func TestGateRemoteFetchableDefersToResolver(t *testing.T) {
	s := minimalMediaServer(mediafetch.DefaultConfig())
	_, parsed := chatBodyBytes(t, "https://example.com/cat.png")
	w := httptest.NewRecorder()
	if s.gateRemoteMediaPreDispatch(w, plainReq(), parsed, "test", "test", true, false) {
		t.Fatalf("fetchable remote URL must defer to post-reservation resolution, body=%s", w.Body.String())
	}
}

func TestGateUnfetchableShapeRejected(t *testing.T) {
	s := minimalMediaServer(mediafetch.DefaultConfig())
	// Anthropic source block with a remote URL: the resolver does not fetch this
	// shape and the provider silently drops it (image-blind) — must keep the
	// clean pre-dispatch 400.
	parsed := map[string]any{
		"model": "test",
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "image", "source": map[string]any{"type": "url", "url": "https://example.com/a.png"}},
		}}},
	}
	w := httptest.NewRecorder()
	if !s.gateRemoteMediaPreDispatch(w, plainReq(), parsed, "test", "test", true, false) {
		t.Fatal("unfetchable remote shape must be rejected pre-dispatch")
	}
	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestGateDisabledFallsBackToLegacyReject(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.Enabled = false
	s := minimalMediaServer(cfg)
	_, parsed := chatBodyBytes(t, "https://example.com/cat.png")

	w := httptest.NewRecorder()
	if !s.gateRemoteMediaPreDispatch(w, plainReq(), parsed, "test", "test", true, false) {
		t.Fatal("resolver disabled: remote URL must hit the legacy rejection")
	}
	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}

	// The retired DARKBLOOM_VISION_REJECT_REMOTE_URLS switch is read nowhere
	// anymore: setting it must not turn fetch-disabled rollback back into
	// dispatch-then-provider-400.
	t.Setenv("DARKBLOOM_VISION_REJECT_REMOTE_URLS", "false")
	w2 := httptest.NewRecorder()
	if !s.gateRemoteMediaPreDispatch(w2, plainReq(), parsed, "test", "test", true, false) {
		t.Fatal("fetch-disabled gate must reject regardless of the legacy flag")
	}
	if w2.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", w2.Code)
	}
}

func TestGateNonVisionNoOp(t *testing.T) {
	s := minimalMediaServer(mediafetch.DefaultConfig())
	if s.gateRemoteMediaPreDispatch(httptest.NewRecorder(), plainReq(), map[string]any{}, "test", "test", false, false) {
		t.Fatal("non-vision requests must never be gated")
	}
}

func TestScanRemoteMediaRefs(t *testing.T) {
	openaiRemote := map[string]any{"type": "image_url", "image_url": map[string]any{"url": "https://x/a.png"}}
	anthropicRemote := map[string]any{"type": "image", "source": map[string]any{"type": "url", "url": "https://x/b.png"}}
	inline := map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,AAAA"}}
	fileScheme := map[string]any{"type": "image_url", "image_url": map[string]any{"url": "file:///etc/passwd"}}

	mk := func(parts ...map[string]any) map[string]any {
		anyParts := make([]any, len(parts))
		for i, p := range parts {
			anyParts[i] = p
		}
		return map[string]any{"messages": []any{map[string]any{"role": "user", "content": anyParts}}}
	}

	for _, tc := range []struct {
		name                    string
		body                    map[string]any
		wantRemote, wantUnfetch string
	}{
		{"text only", map[string]any{"messages": []any{map[string]any{"role": "user", "content": "hi"}}}, "", ""},
		{"inline only", mk(inline), "", ""},
		// Fetchable: remote, but nothing for the unfetchable-shape gate.
		{"fetchable openai part", mk(openaiRemote, inline), "https://x/a.png", ""},
		{"anthropic beside fetchable", mk(openaiRemote, anthropicRemote), "https://x/a.png", "https://x/b.png"},
		// URL equality must not make an unsupported shape fetchable: each part is
		// judged by its own shape and location.
		{"same url, both shapes", mk(
			map[string]any{"type": "image_url", "image_url": map[string]any{"url": "https://x/s.png"}},
			map[string]any{"type": "image", "source": map[string]any{"type": "url", "url": "https://x/s.png"}},
		), "https://x/s.png", "https://x/s.png"},
		{"file scheme", mk(fileScheme), "file:///etc/passwd", "file:///etc/passwd"},
		{"responses input surface", map[string]any{"input": []any{
			map[string]any{"content": []any{anthropicRemote}},
		}}, "https://x/b.png", "https://x/b.png"},
		// Responses input[] never has a fetchable shape, even for an OpenAI part.
		{"openai part under input", map[string]any{"input": []any{
			map[string]any{"content": []any{openaiRemote}},
		}}, "https://x/a.png", "https://x/a.png"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := scanRemoteMediaRefs(tc.body)
			if got.firstRemote != tc.wantRemote {
				t.Errorf("firstRemote = %q, want %q", got.firstRemote, tc.wantRemote)
			}
			if got.firstUnfetchable != tc.wantUnfetch {
				t.Errorf("firstUnfetchable = %q, want %q", got.firstUnfetchable, tc.wantUnfetch)
			}
		})
	}
}

// TestGateSealedRejectsEveryRemoteShape pins that a sealed request is refused
// for ANY remote reference, not just the ones the resolver would fetch. Keying
// the sealed branch off the fetchable subset sent an Anthropic source-URL
// sender the unfetchable-shape message, which advises sending an OpenAI http(s)
// link — advice for something a sealed request will never do either.
func TestGateSealedRejectsEveryRemoteShape(t *testing.T) {
	s := minimalMediaServer(mediafetch.DefaultConfig())
	for _, tc := range []struct {
		name string
		part map[string]any
	}{
		{"openai image_url", map[string]any{"type": "image_url", "image_url": map[string]any{"url": "https://x/a.png"}}},
		{"anthropic source url", map[string]any{"type": "image", "source": map[string]any{"type": "url", "url": "https://x/b.png"}}},
		{"responses input_image", map[string]any{"type": "input_image", "image_url": "https://x/c.png"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := map[string]any{"messages": []any{
				map[string]any{"role": "user", "content": []any{tc.part}},
			}}
			w := httptest.NewRecorder()
			if !s.gateRemoteMediaPreDispatch(w, sealedReq(), body, "test", "test", true, false) {
				t.Fatal("a sealed request carrying a remote media reference must be rejected")
			}
			if got := w.Body.String(); !strings.Contains(got, "sealed requests must send media as an inline") {
				t.Errorf("sealed request got the wrong guidance: %s", got)
			}
		})
	}
}

func TestResolveRemoteMediaSelfRouteUnavailableSkipsFetch(t *testing.T) {
	srv, _ := testServer(t) // real registry + store, no linked providers
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	w := httptest.NewRecorder()
	meta := mediaResolveMeta{
		model: "test", publicModel: "test", requiresVision: true,
		selfRoute: true, ownerAccountID: "owner-with-no-machine",
	}
	out, _, ok := srv.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, meta)
	if ok || out != nil {
		t.Fatal("self-route with no serving machine must not resolve media")
	}
	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 (no_linked_machine)", w.Code)
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("unserviceable self-route triggered %d origin fetch(es); want 0", n)
	}
}

// --- full HTTP path through srv.Handler() ------------------------------------

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

func TestChatCompletionsRemoteMediaRequiresMediaAwareBalanceBeforeFetch(t *testing.T) {
	srv, st := testBillingServer(t)
	makeVisionRoutableProvider(t, srv.registry, "vision-balance", "test")
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)
	// Make the prompt-token difference visible above the universal minimum fee.
	if err := st.SetModelPrice("platform", "test", 1_000_000, 0); err != nil {
		t.Fatal(err)
	}

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()
	_, parsed := chatBodyBytes(t, media.URL+"/private.png")
	parsed["max_tokens"] = 1
	body, err := json.Marshal(parsed)
	if err != nil {
		t.Fatal(err)
	}
	estimated := estimatePromptTokens(parsed)
	billing := estimateBillingPromptTokens(parsed)
	if estimated <= billing {
		t.Fatalf("test setup requires media estimate > URL-byte bound; estimated=%d billing=%d", estimated, billing)
	}
	urlOnlyCost := srv.reservationCost("test", billing, 1)
	mediaAwareCost := srv.reservationCost("test", estimated, 1)
	if mediaAwareCost <= urlOnlyCost {
		t.Fatalf("test setup requires distinct costs; URL=%d media=%d", urlOnlyCost, mediaAwareCost)
	}
	if err := st.Credit(testConsumerID, urlOnlyCost, store.LedgerDeposit, "media-prefetch-floor"); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusPaymentRequired {
		t.Fatalf("status = %d, want 402; body=%s", w.Code, w.Body.String())
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("insufficient media-aware balance triggered %d origin fetch(es); want 0", n)
	}
}

func TestChatCompletionsRemoteMediaSSRFBlocked(t *testing.T) {
	srv, _ := testServer(t)
	makeVisionRoutableProvider(t, srv.registry, "vision-ssrf", "test")
	cfg := mediafetch.DefaultConfig()
	cfg.AllowNonStandardPorts = true // isolate connect-time loopback blocking from the port gate
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)

	media := httptest.NewServer(pngHandler(t, nil))
	defer media.Close()

	body, _ := chatBodyBytes(t, media.URL+"/x.png") // loopback → must be blocked at dial time
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
	srv, _ := testServer(t)
	makeVisionRoutableProvider(t, srv.registry, "vision-ok", "test")
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true // loopback httptest origin
	cfg.AllowNonStandardPorts = true
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)

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
	// outcome — anything but the media-gate 4xx family proves the media step.
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("origin hit %d time(s), want exactly 1; status=%d body=%.200s", n, w.Code, w.Body.String())
	}
	if w.Code == http.StatusBadRequest || w.Code == http.StatusForbidden {
		t.Errorf("request died at the media gate: %d %s", w.Code, w.Body.String())
	}
}

func TestChatCompletionsRemoteMediaDisabledLegacyReject(t *testing.T) {
	srv, _ := testServer(t)
	makeVisionRoutableProvider(t, srv.registry, "vision-disabled", "test")
	cfg := mediafetch.DefaultConfig()
	cfg.Enabled = false
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)

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

// TestPreludeDefersRemoteMediaResolution locks in the cost-gate ordering: the
// shared parseInferencePrelude must NOT fetch/inline remote media. Resolution is
// deferred to the chat handler AFTER token admission + the balance reservation,
// so an authenticated but unfunded/over-quota request can never drive
// coordinator-side fetches. A remote URL therefore survives the prelude
// unchanged and no fetch occurs. The resolver here permits loopback, so it
// WOULD inline successfully if the prelude (wrongly) invoked it — proving the
// deferral, not a fetch failure.
func TestPreludeDefersRemoteMediaResolution(t *testing.T) {
	srv, _ := testServer(t)
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
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

// TestMediaRejectionReasonMapping pins the media-failure status → rejection-ledger
// reason_code mapping. Filing everything but 413 as "bad_param" made a blocked
// host, a slow origin and a broken upstream indistinguishable from a malformed
// consumer request on the rejection dashboards.
func TestMediaRejectionReasonMapping(t *testing.T) {
	cases := []struct {
		name   string
		status int
		want   string
	}{
		{"blocked host or resolved address", http.StatusForbidden, "media_blocked"},
		{"origin took too long", http.StatusRequestTimeout, "upstream_timeout"},
		{"upstream failed", http.StatusBadGateway, "upstream_error"},
		{"upstream gateway timeout", http.StatusGatewayTimeout, "upstream_error"},
		{"media too large", http.StatusRequestEntityTooLarge, "payload_too_large"},
		{"malformed consumer request", http.StatusBadRequest, "bad_param"},
		{"unmapped status falls back", http.StatusInternalServerError, "bad_param"},
	}
	for _, c := range cases {
		if got := mediaRejectionReason(c.status); got != c.want {
			t.Errorf("%s: mediaRejectionReason(%d) = %q, want %q", c.name, c.status, got, c.want)
		}
	}
}

// TestMediaFetchRejectedPreservesAPIContract guards the other half of the remap:
// the consumer-visible status, error type and message are API contract and must
// not shift when the internal reason_code changes.
func TestMediaFetchRejectedPreservesAPIContract(t *testing.T) {
	s := minimalMediaServer(mediafetch.DefaultConfig())
	w := httptest.NewRecorder()
	s.mediaFetchRejected(w, plainReq(), map[string]any{},
		mediaResolveMeta{model: "test", publicModel: "test"},
		http.StatusForbidden, "media_blocked", "a media URL host is not allowed")

	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", w.Code)
	}
	var body struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body.Error.Type != "media_blocked" {
		t.Errorf("error.type = %q, want media_blocked", body.Error.Type)
	}
	if body.Error.Message != "a media URL host is not allowed" {
		t.Errorf("error.message = %q, want the unchanged public message", body.Error.Message)
	}
}

// TestResolveRemoteMediaSelfRouteUsesFullTraits pins that the pre-fetch
// self-route gate judges serve-ability with the SAME traits the real admission
// uses. Reconstructing a partial set (HasTools only) called an owned provider
// serviceable when the request needed a trait it does not advertise — here a
// constrained tool_choice (RequiresToolConstraint) — so the media was fetched
// and only then rejected by runInferenceAdmission. That is the exact
// egress-before-rejection hole the self-route gate exists to close.
func TestResolveRemoteMediaSelfRouteUsesFullTraits(t *testing.T) {
	srv, _ := testServer(t)
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	srv.mediaResolver = mediafetch.NewResolver(cfg, srv.logger)

	// An owned, online, vision- and tool-capable machine that does NOT advertise
	// the tool-constraint protocol: serviceable for HasTools alone, ineligible
	// once RequiresToolConstraint is included.
	const owner = "owner-acct"
	makeVisionRoutableProvider(t, srv.registry, "self-route-traits", "test")
	for _, id := range srv.registry.ProviderIDs() {
		if p := srv.registry.GetProvider(id); p != nil {
			p.Mu().Lock()
			p.AccountID = owner
			// Well above the tools version floor, so HasTools alone is satisfied
			// and ToolConstraintProtocol (left unset, i.e. not v1) is the ONLY
			// reason the request is ineligible. Without this the provider fails
			// the floor either way and the test cannot see the trait delta.
			p.Version = "0.7.6"
			p.Mu().Unlock()
		}
	}
	// Sanity: the partial trait set the gate used to reconstruct MUST consider
	// this provider serviceable, or the assertion below proves nothing.
	if !srv.registry.HasToolCapableProviderForModel("test") {
		t.Fatal("setup: provider must satisfy the plain tools floor")
	}

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	w := httptest.NewRecorder()
	out, _, ok := srv.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, mediaResolveMeta{
		model: "test", publicModel: "test", requiresVision: true,
		selfRoute: true, ownerAccountID: owner, hasTools: true,
		traits: registry.RequestTraits{HasTools: true, RequiresToolConstraint: true},
	})
	if ok || out != nil {
		t.Fatal("a self-route request needing an unadvertised trait must not resolve media")
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("trait-ineligible self-route triggered %d origin fetch(es); want 0", n)
	}
}
