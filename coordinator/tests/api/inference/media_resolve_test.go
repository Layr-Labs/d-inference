package inference_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	infermedia "github.com/eigeninference/d-inference/coordinator/internal/inference/media"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/payments"
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

func TestResolveRemoteMediaSelfRouteUnavailableSkipsFetch(t *testing.T) {
	srv, _ := testServer(t) // real registry + store, no linked providers
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	bridge := mediaAvailabilityBridge(srv, cfg)

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	w := httptest.NewRecorder()
	meta := infermedia.ResolveMeta{
		Model: "test", PublicModel: "test", RequiresVision: true,
		SelfRoute: true, OwnerAccountID: "owner-with-no-machine",
	}
	out, _, ok := bridge.Resolve(w, plainReq(), raw, parsed, &registry.RequestTiming{}, meta)
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

func TestChatCompletionsRemoteMediaRequiresMediaAwareBalanceBeforeFetch(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	srv, st := testMediaBillingServer(t, cfg)
	makeVisionRoutableProvider(t, srv.registry, "vision-balance", "test")
	// Make the prompt-token difference visible above the universal minimum fee.
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: "test", InputPrice: 1_000_000, OutputPrice: 0}); err != nil {
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
	estimated := inreq.EstimatePromptTokens(parsed)
	billing := inreq.EstimateBillingPromptTokens(parsed)
	if estimated <= billing {
		t.Fatalf("test setup requires media estimate > URL-byte bound; estimated=%d billing=%d", estimated, billing)
	}
	rates := payments.RatesFor(st.GetModelPrice("platform", "test"))
	urlOnlyCost := rates.CostWithMinimum(payments.Usage{PromptTokens: billing, CompletionTokens: 1})
	mediaAwareCost := rates.CostWithMinimum(payments.Usage{PromptTokens: estimated, CompletionTokens: 1})
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

// TestPreludeDefersRemoteMediaResolution locks in the cost-gate ordering: the
// shared parseInferencePrelude must NOT fetch/inline remote media. Resolution is
// deferred to the chat handler AFTER token admission + the balance reservation,
// so an authenticated but unfunded/over-quota request can never drive
// coordinator-side fetches. A remote URL therefore survives the prelude
// unchanged and no fetch occurs. The resolver here permits loopback, so it
// WOULD inline successfully if the prelude (wrongly) invoked it — proving the
// deferral, not a fetch failure.
func TestPreludeDefersRemoteMediaResolution(t *testing.T) {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true
	cfg.AllowNonStandardPorts = true
	srv, _ := testServerWithConfig(t, TestServerConfig{MediaFetch: &cfg})

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	body, _ := chatBodyBytes(t, media.URL+"/x.png")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	w := httptest.NewRecorder()

	prelude, ok := srv.NewPreludeParser().Parse(w, req)
	if !ok {
		t.Fatalf("prelude unexpectedly failed: %s", w.Body.String())
	}
	rawBody, err := prelude.Body.Current()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(rawBody, []byte("http://")) {
		t.Errorf("prelude inlined the remote URL; media resolution must be deferred to post-billing")
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Errorf("prelude fetched media %d time(s); must be 0 (resolution is deferred to post-billing)", n)
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
	bridge := mediaAvailabilityBridge(srv, cfg)

	// An owned, online, vision- and tool-capable machine that does NOT advertise
	// the tool-constraint protocol: serviceable for HasTools alone, ineligible
	// once RequiresToolConstraint is included.
	const owner = "owner-acct"
	makeVisionRoutableProvider(t, srv.registry, "self-route-traits", "test")
	for _, id := range srv.registry.ProviderIDs() {
		if p := srv.registry.GetProvider(id); p != nil {
			p.Mu().Lock()
			p.AccountID = owner
			// HasTools alone is satisfied, so ToolConstraintProtocol (left
			// unset, i.e. not v1) is the ONLY reason the request is ineligible.
			p.Version = "0.7.6"
			p.Mu().Unlock()
		}
	}
	// Sanity: the partial trait set the gate used to reconstruct MUST consider
	// this provider serviceable, or the assertion below proves nothing.
	if !srv.registry.HasToolCapableProviderForModel("test") {
		t.Fatal("setup: provider must satisfy the plain tools gate")
	}

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()

	raw, parsed := chatBodyBytes(t, media.URL+"/cat.png")
	w := httptest.NewRecorder()
	out, _, ok := bridge.Resolve(w, plainReq(), raw, parsed, &registry.RequestTiming{}, infermedia.ResolveMeta{
		Model: "test", PublicModel: "test", RequiresVision: true,
		SelfRoute: true, OwnerAccountID: owner, HasTools: true,
		Traits: registry.RequestTraits{HasTools: true, RequiresToolConstraint: true},
	})
	if ok || out != nil {
		t.Fatal("a self-route request needing an unadvertised trait must not resolve media")
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("trait-ineligible self-route triggered %d origin fetch(es); want 0", n)
	}
}

func mediaAvailabilityBridge(srv *serverFixture, cfg mediafetch.Config) *infermedia.Bridge {
	return infermedia.NewBridge(infermedia.Dependencies{
		Resolver: mediafetch.NewResolver(cfg, quietLogger()), Logger: quietLogger(), Observation: srv.observation,
		SelfRouteUnavailable: (routeplan.Availability{Registry: srv.registry, Store: srv.store}).Unavailable,
		RecordRemote:         func(*http.Request, map[string]any, string, string, bool) {},
		RecordRejection:      func(*http.Request, map[string]any, infermedia.ResolveMeta, int) {},
	})
}
