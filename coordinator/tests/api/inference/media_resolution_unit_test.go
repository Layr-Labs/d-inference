package inference_test

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	infermedia "github.com/eigeninference/d-inference/coordinator/internal/inference/media"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

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
	s.deadline = 5 * time.Second
	raw, parsed := chatBodyBytes(t, "data:image/png;base64,iVBORw0KGgo=")
	w := httptest.NewRecorder()
	timing := &registry.RequestTiming{ReceivedAt: time.Now().Add(-15 * time.Second)}

	out, inlined, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, timing, testMeta())
	if !ok || inlined || !bytes.Equal(out, raw) {
		t.Fatalf("inline-only body must pass through unchanged (ok=%v inlined=%v)", ok, inlined)
	}
	if !timing.MediaFetchedAt.IsZero() {
		t.Error("MediaFetchedAt must stay zero when nothing was fetched")
	}
}

func TestMediaFetchBudgetUnstampedKeepsHistoricalPath(t *testing.T) {
	budget, bound := infermedia.FetchBudget(time.Time{}, 9*time.Second)
	if bound || budget != 0 {
		t.Fatalf("unstamped clock = (%s,%v), want unbounded", budget, bound)
	}
}

func TestMediaFetchBudgetProductionLeavesInferenceReserve(t *testing.T) {
	deadline := 9*time.Second + 1500*time.Millisecond
	budget, bound := infermedia.FetchBudget(time.Now(), deadline)
	if !bound {
		t.Fatal("stamped production clock must bound the fetch")
	}
	// reserve = min(5s, 10.5s/2) = 5s; leftover ≈ 10.5s → budget ≈ 5.5s
	if budget < 5*time.Second || budget > 6*time.Second {
		t.Fatalf("production video budget = %s, want ~5.5s", budget)
	}
}

func TestMediaFetchBudgetTestDefaultDeadlineStillFetches(t *testing.T) {
	budget, bound := infermedia.FetchBudget(time.Now(), 5*time.Second)
	if !bound {
		t.Fatal("stamped 5s clock must still bound")
	}
	// reserve shrinks to deadline/2 = 2.5s so ordinary test servers still fetch
	if budget < 2*time.Second || budget > 3*time.Second {
		t.Fatalf("5s deadline budget = %s, want ~2.5s", budget)
	}
}

func TestMediaFetchBudgetUsesPinnedQwenDeadline(t *testing.T) {
	srv, _ := testServerWithConfig(t, TestServerConfig{
		FirstContentDeadlineBase: 9 * time.Second,
	})
	deadline := srv.FirstContentDeadline(
		modelpolicy.Qwen3VL30BA3BInstructModelID, 300,
	)
	if want := 4*time.Second + 300*time.Millisecond; deadline != want {
		t.Fatalf("Qwen3-VL deadline = %s, want %s", deadline, want)
	}
	budget, bound := infermedia.FetchBudget(time.Now(), deadline)
	if !bound {
		t.Fatal("stamped Qwen3-VL clock must bound the fetch")
	}
	// For a sub-5s clock the resolver reserves half for inference, so remote
	// media gets roughly 2.15s and cannot consume the full first-content SLA.
	if budget < 1900*time.Millisecond || budget > 2300*time.Millisecond {
		t.Fatalf("Qwen3-VL media budget = %s, want ~2.15s", budget)
	}
}

func TestMediaFetchBudgetExpiredClockIsZero(t *testing.T) {
	budget, bound := infermedia.FetchBudget(time.Now().Add(-15*time.Second), 9*time.Second)
	if !bound || budget != 0 {
		t.Fatalf("expired clock = (%s,%v), want 0+bound", budget, bound)
	}
}

func TestResolveRemoteMediaExpiredFirstContentClockDoesNotFetch(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	s := minimalMediaServer(cfg)
	s.deadline = 9 * time.Second
	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	w := httptest.NewRecorder()
	timing := &registry.RequestTiming{ReceivedAt: time.Now().Add(-15 * time.Second)}

	meta := testMeta()
	meta.FirstContentDeadline = 9 * time.Second
	meta.FirstContentDeadlineSet = true
	out, _, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, timing, meta)
	if ok || out != nil {
		t.Fatal("expired first-content clock must not fetch")
	}
	if atomic.LoadInt32(&hits) != 0 {
		t.Fatalf("origin was fetched %d times", hits)
	}
	if w.Code != http.StatusRequestTimeout {
		t.Fatalf("status=%d body=%s, want 408", w.Code, w.Body.String())
	}
}

func TestResolveRemoteMediaUsesPinnedDeadlineWithoutRecomputing(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	s := minimalMediaServer(cfg)
	s.deadline = 9 * time.Second
	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	w := httptest.NewRecorder()
	timing := &registry.RequestTiming{ReceivedAt: time.Now().Add(-200 * time.Millisecond)}
	meta := testMeta()
	meta.FirstContentDeadline = 100 * time.Millisecond

	out, _, ok := s.resolveRemoteMedia(w, plainReq(), raw, parsed, timing, meta)
	if ok || out != nil {
		t.Fatal("expired pinned media deadline must not be recomputed from the 9s server base")
	}
	if got := atomic.LoadInt32(&hits); got != 0 {
		t.Fatalf("origin was fetched %d times, want 0", got)
	}
	if w.Code != http.StatusRequestTimeout {
		t.Fatalf("status=%d body=%s, want 408", w.Code, w.Body.String())
	}
}

func TestResolveRemoteMediaPinnedSLAExemptionDoesNotRecompute(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()
	s := minimalMediaServer(cfg)
	// Even a later selector match must not replace a pinned zero budget.
	s.deadline = 9 * time.Second
	s.onDeadline = func() { t.Fatal("pinned exemption recomputed the account SLA") }
	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	meta := testMeta()
	meta.FirstContentDeadlineSet = true
	w := httptest.NewRecorder()
	out, inlined, ok := s.resolveRemoteMedia(w, mediaSLAAccountRequest("selected-account"), raw, parsed,
		&registry.RequestTiming{ReceivedAt: time.Now().Add(-15 * time.Second)}, meta)
	if !ok || !inlined || len(out) == 0 || atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("pinned exemption fetched=%d ok=%v inlined=%v body=%s", hits, ok, inlined, w.Body)
	}
}

func TestResolveRemoteMediaNilResolverPassthrough(t *testing.T) {
	s := newMediaFixture(nil, quietLogger()) // e.g. a bare test Server
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
	s := newMediaFixture(mediafetch.NewResolver(cfg, logger), logger)

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
			got := infermedia.ScanRemoteRefs(tc.body)
			if got.FirstRemote != tc.wantRemote {
				t.Errorf("firstRemote = %q, want %q", got.FirstRemote, tc.wantRemote)
			}
			if got.FirstUnfetchable != tc.wantUnfetch {
				t.Errorf("firstUnfetchable = %q, want %q", got.FirstUnfetchable, tc.wantUnfetch)
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
		if got := infermedia.RejectionReason(c.status); got != c.want {
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
		infermedia.ResolveMeta{Model: "test", PublicModel: "test"},
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
