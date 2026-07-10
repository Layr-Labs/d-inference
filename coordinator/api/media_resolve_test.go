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

	out, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, timing, testMeta())
	if !ok {
		t.Fatalf("resolveRemoteMedia ok=false, body=%s", w.Body.String())
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

	out, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, timing, testMeta())
	if !ok || !bytes.Equal(out, raw) {
		t.Fatalf("inline-only body must pass through unchanged (ok=%v)", ok)
	}
	if !timing.MediaFetchedAt.IsZero() {
		t.Error("MediaFetchedAt must stay zero when nothing was fetched")
	}
}

func TestResolveRemoteMediaNilResolverPassthrough(t *testing.T) {
	s := &Server{logger: quietLogger()} // e.g. a bare test Server
	raw, parsed := chatBodyBytes(t, "https://example.com/cat.png")
	w := httptest.NewRecorder()

	out, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, testMeta())
	if !ok || !bytes.Equal(out, raw) {
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

	out, ok := s.resolveRemoteMedia(w, req, raw, parsed, &registry.RequestTiming{}, testMeta())
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

	out, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, testMeta())
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

	if out, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, testMeta()); ok || out != nil {
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

	// The new kill switch is authoritative: the legacy rejection flag cannot
	// turn fetch-disabled rollback into dispatch-then-provider-400.
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

func TestFirstUnfetchableRemoteRef(t *testing.T) {
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

	// All refs fetchable → ok.
	body := mk(openaiRemote, inline)
	if ref, ok := firstUnfetchableRemoteRef(body); !ok {
		t.Errorf("fetchable-only body flagged %q", ref)
	}
	// Anthropic remote next to a fetchable OpenAI part → flagged.
	body = mk(openaiRemote, anthropicRemote)
	if ref, ok := firstUnfetchableRemoteRef(body); ok || ref != "https://x/b.png" {
		t.Errorf("anthropic remote must be flagged; got (%q,%v)", ref, ok)
	}
	// URL equality must not make an unsupported shape fetchable: each part is
	// judged by its own shape/location.
	sharedURL := "https://x/shared.png"
	body = mk(
		map[string]any{"type": "image_url", "image_url": map[string]any{"url": sharedURL}},
		map[string]any{"type": "image", "source": map[string]any{"type": "url", "url": sharedURL}},
	)
	if ref, ok := firstUnfetchableRemoteRef(body); ok || ref != sharedURL {
		t.Errorf("same-URL unsupported block must be flagged; got (%q,%v)", ref, ok)
	}
	// file:// scheme in an OpenAI part: not collected by the resolver → flagged.
	body = mk(fileScheme)
	if ref, ok := firstUnfetchableRemoteRef(body); ok || ref != "file:///etc/passwd" {
		t.Errorf("file:// must be flagged; got (%q,%v)", ref, ok)
	}
	// Responses input[] surface is walked too.
	body = map[string]any{"input": []any{map[string]any{"content": []any{anthropicRemote}}}}
	if _, ok := firstUnfetchableRemoteRef(body); ok {
		t.Error("input[] remote refs must be flagged")
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
	out, ok := srv.resolveRemoteMedia(w, plainReq(), raw, parsed, &registry.RequestTiming{}, meta)
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
