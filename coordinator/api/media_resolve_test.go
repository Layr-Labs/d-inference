package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inferencefixture"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
	media := httptest.NewServer(inferencefixture.PNGHandler(t, &hits))
	defer media.Close()
	_, parsed := inferencefixture.ChatBody(t, media.URL+"/private.png")
	parsed["max_tokens"] = 1
	body, err := json.Marshal(parsed)
	if err != nil {
		t.Fatal(err)
	}
	estimated := inferencefixture.PromptTokens(parsed)
	billing := inferencefixture.BillingTokens(parsed)
	if estimated <= billing {
		t.Fatalf("test setup requires media estimate > URL-byte bound; estimated=%d billing=%d", estimated, billing)
	}
	urlOnlyCost := srv.inferenceSettlement().Estimate("test", billing, 1)
	mediaAwareCost := srv.inferenceSettlement().Estimate("test", estimated, 1)
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

	media := httptest.NewServer(inferencefixture.PNGHandler(t, nil))
	defer media.Close()

	body, _ := inferencefixture.ChatBody(t, media.URL+"/x.png") // loopback → must be blocked at dial time
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403; body=%s", w.Code, w.Body.String())
	}
	if code := inferencefixture.ErrorType(t, w.Body.Bytes()); code != "media_blocked" {
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
	media := httptest.NewServer(inferencefixture.PNGHandler(t, &hits))
	defer media.Close()

	body, _ := inferencefixture.ChatBody(t, media.URL+"/cat.png")
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
	body, _ := inferencefixture.ChatBody(t, "https://example.com/cat.png")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", w.Code, w.Body.String())
	}
	if code := inferencefixture.ErrorType(t, w.Body.Bytes()); code != "invalid_request_error" {
		t.Errorf("error code = %q, want invalid_request_error (legacy reject)", code)
	}
	if !strings.Contains(w.Body.String(), "data:") {
		t.Errorf("legacy rejection must point at the data: URI contract: %s", w.Body.String())
	}
}
