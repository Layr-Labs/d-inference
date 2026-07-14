package registry

import (
	"encoding/base64"
	"fmt"
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func testCacheRoutingConfig(mode string) CacheRoutingConfig {
	return CacheRoutingConfig{
		Mode: mode, TTL: defaultCacheRoutingTTL, MaxHolders: 4,
		MaxDiscountMs: 1000, MaxCostFraction: .35,
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
	}
}

func TestCacheRouteDerivationIsolationAndPrecedence(t *testing.T) {
	reg := New(testLogger())
	if err := reg.ConfigureCacheRouting(testCacheRoutingConfig(CacheRoutingConversation)); err != nil {
		t.Fatal(err)
	}
	body := []byte(`{"model":"alias","session_id":"body-session","prompt_cache_key":"prompt-key","messages":[{"role":"system","content":"rules"},{"role":"user","content":"hello"}]}`)
	a := reg.DeriveCacheRoute("acct-a", "build-a", "/v1/chat/completions", body, "header-session", false)
	b := reg.DeriveCacheRoute("acct-b", "build-a", "/v1/chat/completions", body, "header-session", false)
	c := reg.DeriveCacheRoute("acct-a", "build-b", "/v1/chat/completions", body, "header-session", false)
	if a.ExactKey == "" || a.ConversationKey == "" || a.ConversationKind != "explicit" {
		t.Fatalf("incomplete route: %+v", a)
	}
	if a.ExactKey == b.ExactKey || a.ConversationKey == b.ConversationKey {
		t.Fatal("route keys crossed account boundary")
	}
	if a.ExactKey == c.ExactKey || a.ConversationKey == c.ConversationKey {
		t.Fatal("route keys crossed concrete-model boundary")
	}
	if !strings.HasPrefix(a.ScopeNamespace, "session_id:") {
		t.Fatalf("scope namespace %q did not honor body session precedence", a.ScopeNamespace)
	}

	deleteSession := []byte(`{"model":"alias","prompt_cache_key":"prompt-key","messages":[{"role":"user","content":"hello"}]}`)
	header := reg.DeriveCacheRoute("acct-a", "build-a", "/v1/chat/completions", deleteSession, "header-session", false)
	if !strings.HasPrefix(header.ScopeNamespace, "x-session-id:") {
		t.Fatalf("scope namespace %q did not honor header over prompt key", header.ScopeNamespace)
	}
	withoutHeader := reg.DeriveCacheRoute("acct-a", "build-a", "/v1/chat/completions", deleteSession, "", false)
	if !strings.HasPrefix(withoutHeader.ScopeNamespace, "prompt_cache_key:") {
		t.Fatalf("scope namespace %q did not use prompt key", withoutHeader.ScopeNamespace)
	}
	otherHeader := reg.DeriveCacheRoute("acct-a", "build-a", "/v1/chat/completions", deleteSession, "other-header-session", false)
	if header.ExactKey == otherHeader.ExactKey {
		t.Fatal("different X-Session-Id namespaces shared exact evidence")
	}
	bodySessionA := reg.DeriveCacheRoute("acct-a", "build-a", "/v1/chat/completions", body, "header-a", false)
	bodySessionB := reg.DeriveCacheRoute("acct-a", "build-a", "/v1/chat/completions", body, "header-b", false)
	if bodySessionA.ExactKey != bodySessionB.ExactKey || bodySessionA.ScopeNamespace != bodySessionB.ScopeNamespace {
		t.Fatal("X-Session-Id overrode body session_id precedence")
	}
}

func TestCacheRoutingOffDerivesNothing(t *testing.T) {
	reg := New(testLogger())
	route := reg.DeriveCacheRoute("account", "model", "/v1/chat/completions", []byte(`{"messages":[{"role":"user","content":"hello"}]}`), "session", false)
	if route != (CacheRoute{}) {
		t.Fatalf("off mode derived route keys: %+v", route)
	}
}

func TestCacheRoutingOffStillIsolatesLegacyProviderBody(t *testing.T) {
	reg := New(testLogger())
	pr := &PendingRequest{RequestID: "request", Model: "model", ConsumerKey: "account"}
	legacy := &Provider{ID: "legacy", PrefixCacheProtocol: 0}
	if err := reg.PrepareCacheAttempt(pr, legacy); err != nil {
		t.Fatal(err)
	}
	if pr.LegacyCacheBustKey == "" || pr.CacheReceiptNonce != "" || pr.CacheScope != "" {
		t.Fatalf("off-mode legacy preparation = bust %q nonce %q scope %q", pr.LegacyCacheBustKey, pr.CacheReceiptNonce, pr.CacheScope)
	}
}

func TestCacheExactIncludesExplicitNamespace(t *testing.T) {
	reg := New(testLogger())
	if err := reg.ConfigureCacheRouting(testCacheRoutingConfig(CacheRoutingExact)); err != nil {
		t.Fatal(err)
	}
	one := reg.DeriveCacheRoute("acct", "build", "/v1/chat/completions", []byte(`{"prompt_cache_key":"one","messages":[{"role":"user","content":"same"}]}`), "", false)
	two := reg.DeriveCacheRoute("acct", "build", "/v1/chat/completions", []byte(`{"prompt_cache_key":"two","messages":[{"role":"user","content":"same"}]}`), "", false)
	if one.ExactKey == two.ExactKey {
		t.Fatal("different provider cache namespaces shared an exact route key")
	}
}

func TestDerivedConversationAnchorEndpointRules(t *testing.T) {
	reg := New(testLogger())
	if err := reg.ConfigureCacheRouting(testCacheRoutingConfig(CacheRoutingConversation)); err != nil {
		t.Fatal(err)
	}
	longUser := strings.Repeat("x", 1500) + "tail"
	msg := []byte(`{"system":"anthropic rules","messages":[{"role":"user","content":"` + longUser + `"}],"verbosity":"high","parallel_tool_calls":true}`)
	a := reg.DeriveCacheRoute("acct", "build", "/v1/messages", msg, "", false)
	changed := []byte(`{"system":"different rules","messages":[{"role":"user","content":"` + longUser + `"}],"verbosity":"high","parallel_tool_calls":true}`)
	b := reg.DeriveCacheRoute("acct", "build", "/v1/messages", changed, "", false)
	if a.ConversationKey == "" || a.ConversationKind != "derived" || a.ConversationKey == b.ConversationKey {
		t.Fatalf("Anthropic derived anchor not deterministic/isolated: a=%+v b=%+v", a, b)
	}
	tailChanged := []byte(`{"system":"anthropic rules","messages":[{"role":"user","content":"` + strings.Repeat("x", 1500) + `different-tail"}],"verbosity":"high","parallel_tool_calls":true}`)
	c := reg.DeriveCacheRoute("acct", "build", "/v1/messages", tailChanged, "", false)
	if a.ConversationKey == c.ConversationKey {
		t.Fatal("derived anchor truncated the first non-system message")
	}
	completion := reg.DeriveCacheRoute("acct", "build", "/v1/completions", []byte(`{"prompt":"hello"}`), "", false)
	if completion.ExactKey == "" || completion.ConversationKey != "" {
		t.Fatalf("plain completion derived conversation key: %+v", completion)
	}
	media := reg.DeriveCacheRoute("acct", "build", "/v1/chat/completions", []byte(`{"messages":[{"role":"user","content":"hello"}]}`), "", true)
	if media.ConversationKey != "" {
		t.Fatal("media request received derived conversation key")
	}
}

func TestProviderCacheScopeIsOpaqueAndBound(t *testing.T) {
	reg := New(testLogger())
	if err := reg.ConfigureCacheRouting(testCacheRoutingConfig(CacheRoutingExact)); err != nil {
		t.Fatal(err)
	}
	a := reg.ProviderCacheScope("account-secret", "model-build", "hash-a", "namespace")
	b := reg.ProviderCacheScope("account-secret", "model-build", "hash-b", "namespace")
	if a == "" || a == b {
		t.Fatalf("scope derivation failed: %q %q", a, b)
	}
	for _, private := range []string{"account-secret", "model-build", "hash-a", "namespace"} {
		if strings.Contains(a, private) {
			t.Fatalf("opaque scope leaked %q", private)
		}
	}
	if got := reg.ProviderCacheScope("acct", "model", "", "namespace"); got != "" {
		t.Fatalf("scope without immutable hash = %q", got)
	}
}

func TestPrepareCacheAttemptVersionAndExpectedHashGates(t *testing.T) {
	reg := New(testLogger())
	if err := reg.ConfigureCacheRouting(testCacheRoutingConfig(CacheRoutingExact)); err != nil {
		t.Fatal(err)
	}
	reg.SetModelCatalog([]CatalogEntry{{ID: "model", WeightHash: "expected-hash"}})
	provider := reg.Register("provider", nil, testRegisterMessage())
	pr := &PendingRequest{RequestID: "request", Model: "model", ConsumerKey: "account", CacheRoute: CacheRoute{ExactKey: "route-key", ScopeNamespace: "namespace"}}
	if err := reg.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if pr.CacheScope != "" || pr.CacheReceiptNonce != "" || pr.LegacyCacheBustKey == "" {
		t.Fatal("legacy provider did not receive only an encrypted-body cache buster")
	}
	firstBust := pr.LegacyCacheBustKey
	if err := reg.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if pr.LegacyCacheBustKey == "" || pr.LegacyCacheBustKey == firstBust {
		t.Fatal("legacy retry reused its prior cache buster")
	}
	provider.mu.Lock()
	provider.PrefixCacheProtocol = 1
	provider.Models = []protocol.ModelInfo{{ID: "model"}}
	provider.mu.Unlock()
	if err := reg.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if pr.CacheScope != "" || pr.CacheReceiptNonce != "" || pr.LegacyCacheBustKey != "" {
		t.Fatal("protocol-v1 provider without a weight hash received cache fields")
	}
	provider.mu.Lock()
	provider.Models = []protocol.ModelInfo{{ID: "model", WeightHash: "mismatched-hash"}}
	provider.mu.Unlock()
	if err := reg.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if pr.CacheScope != "" || pr.CacheReceiptNonce != "" {
		t.Fatal("protocol-v1 provider with a mismatched weight hash received cache fields")
	}
	provider.mu.Lock()
	provider.Models = []protocol.ModelInfo{{ID: "model", WeightHash: "EXPECTED-HASH"}}
	provider.mu.Unlock()
	if err := reg.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if pr.CacheScope == "" || pr.CacheReceiptNonce == "" || strings.Contains(pr.CacheScope, "account") || strings.Contains(pr.CacheScope, "route-key") {
		t.Fatalf("invalid prepared attempt: scope=%q nonce=%q", pr.CacheScope, pr.CacheReceiptNonce)
	}
	if _, ok := reg.cacheRouting.attempts[pr.CacheReceiptNonce]; !ok {
		t.Fatal("nonce was not registered before dispatch")
	}

	reg.SetModelCatalog([]CatalogEntry{{ID: "model"}})
	withoutHash := &PendingRequest{RequestID: "request-2", Model: "model", ConsumerKey: "account", CacheRoute: pr.CacheRoute}
	if err := reg.PrepareCacheAttempt(withoutHash, provider); err != nil {
		t.Fatal(err)
	}
	if withoutHash.CacheScope != "" || withoutHash.CacheReceiptNonce != "" {
		t.Fatal("build without expected immutable hash received cache fields")
	}
}

func TestNegativeWatermarkBlocksDelayedPositiveResurrection(t *testing.T) {
	for _, negative := range []string{"miss_absent", "miss_corrupt", "skipped_capacity"} {
		for _, positive := range []string{"hit", "ready"} {
			t.Run(negative+"_then_older_"+positive, func(t *testing.T) {
				tracker := newCacheRoutingTracker(time.Minute, 4)
				now := time.Unix(140, 0)
				route := CacheRoute{ExactKey: "exact", ConversationKey: "conversation"}
				olderNonce, _ := tracker.registerAttempt("older", "provider", "model", route, now)
				newerNonce, _ := tracker.registerAttempt("newer", "provider", "model", route, now.Add(time.Second))
				if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
					RequestID: "newer", CacheReceiptNonce: newerNonce, Outcome: negative,
				}, now.Add(2*time.Second)) {
					t.Fatal("newer negative receipt rejected")
				}
				delayedAt := now.Add(2 * time.Minute)
				if positive == "hit" {
					if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
						RequestID: "older", CacheReceiptNonce: olderNonce, Outcome: "hit",
						Tier: "memory", CachedTokens: 1000, PrefillTokensSaved: 900,
					}, delayedAt) {
						t.Fatal("delayed older hit receipt rejected")
					}
				} else if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
					RequestID: "older", CacheReceiptNonce: olderNonce, ReadyTokens: 1000,
					RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "memory",
				}, delayedAt) {
					t.Fatal("delayed older ready receipt rejected")
				}
				if hints := tracker.hints(route, CacheRoutingConversation, delayedAt.Add(time.Second)); len(hints) != 0 {
					t.Fatalf("%s resurrected evidence after newer %s: %+v", positive, negative, hints)
				}
			})
		}
	}
}

func TestCacheReceiptNonceLifecycleAndReadyAfterTerminal(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(100, 0)
	route := CacheRoute{ExactKey: "exact", ConversationKey: "conversation", ConversationKind: "explicit"}
	nonce, err := tracker.registerAttempt("request", "provider", "model", route, now)
	if err != nil || nonce == "" {
		t.Fatalf("register attempt: nonce=%q err=%v", nonce, err)
	}
	lookup := &protocol.PrefixCacheLookupMessage{RequestID: "request", CacheReceiptNonce: nonce, Outcome: "hit", Tier: "ssd", CachedTokens: 512, PrefillTokensSaved: 480, StageMs: 4}
	if !tracker.applyLookup("provider", lookup, now.Add(time.Second)) {
		t.Fatal("valid lookup rejected")
	}
	if tracker.applyLookup("provider", lookup, now.Add(2*time.Second)) {
		t.Fatal("duplicate lookup accepted")
	}
	terminalAt := now.Add(110 * time.Minute)
	tracker.markAttemptTerminal(nonce, terminalAt)
	invalidReady := &protocol.PrefixCacheReadyMessage{RequestID: "request", CacheReceiptNonce: nonce, ReadyTokens: 768, RequiredRecomputeTokens: 32, ExpectedPrefillTokensSaved: 700, Tier: "ssd"}
	if tracker.applyReady("provider", invalidReady, terminalAt.Add(time.Minute)) {
		t.Fatal("inconsistent ready savings accepted")
	}
	ready := &protocol.PrefixCacheReadyMessage{RequestID: "request", CacheReceiptNonce: nonce, ReadyTokens: 768, RequiredRecomputeTokens: 32, ExpectedPrefillTokensSaved: 736, Tier: "ssd"}
	if !tracker.applyReady("provider", ready, terminalAt.Add(time.Minute)) {
		t.Fatal("async ready receipt rejected")
	}
	if tracker.applyReady("provider", ready, terminalAt.Add(time.Minute+time.Second)) {
		t.Fatal("non-increasing ready receipt accepted")
	}
	if got := tracker.hints(route, CacheRoutingConversation, terminalAt.Add(time.Minute))["provider"]; got.ReadyTokens != 768 || got.RecomputeTokens != 32 {
		t.Fatalf("ready hint = %+v", got)
	}
}

func TestSSDReadyStageCostIsMeasuredOrConservative(t *testing.T) {
	for _, tc := range []struct {
		name    string
		stageMs float64
		want    float64
	}{
		{name: "measured", stageMs: 17.5, want: 17.5},
		{name: "omitted", stageMs: 0, want: cacheRoutingUnmeasuredSSDStageMs},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tracker := newCacheRoutingTracker(time.Minute, 4)
			now := time.Unix(125, 0)
			route := CacheRoute{ExactKey: "exact"}
			nonce, _ := tracker.registerAttempt("request", "provider", "model", route, now)
			if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
				RequestID: "request", CacheReceiptNonce: nonce, ReadyTokens: 1000,
				RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900,
				Tier: "ssd", StageMs: tc.stageMs,
			}, now.Add(time.Second)) {
				t.Fatal("ready receipt rejected")
			}
			if got := tracker.hints(route, CacheRoutingExact, now.Add(2*time.Second))["provider"].StageMs; got != tc.want {
				t.Fatalf("ready stage = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestSSDReadyStageCostRejectsInvalidNumbers(t *testing.T) {
	for _, stageMs := range []float64{-1, cacheRoutingMaxStageMs + 1, math.NaN(), math.Inf(1), math.Inf(-1)} {
		tracker := newCacheRoutingTracker(time.Minute, 4)
		now := time.Unix(130, 0)
		nonce, _ := tracker.registerAttempt("request", "provider", "model", CacheRoute{ExactKey: "exact"}, now)
		if tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
			RequestID: "request", CacheReceiptNonce: nonce, ReadyTokens: 1000,
			RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900,
			Tier: "ssd", StageMs: stageMs,
		}, now.Add(time.Second)) {
			t.Fatalf("accepted invalid SSD ready stage_ms %v", stageMs)
		}
	}
}

func TestCacheReadyBeforeLookupMissRetainsNewHolder(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(150, 0)
	route := CacheRoute{ExactKey: "exact", ConversationKey: "conversation", ConversationKind: "explicit"}
	nonce, err := tracker.registerAttempt("request", "provider", "model", route, now)
	if err != nil {
		t.Fatal(err)
	}
	ready := &protocol.PrefixCacheReadyMessage{
		RequestID: "request", CacheReceiptNonce: nonce, ReadyTokens: 768,
		RequiredRecomputeTokens: 32, ExpectedPrefillTokensSaved: 736, Tier: "ssd",
	}
	if !tracker.applyReady("provider", ready, now.Add(time.Second)) {
		t.Fatal("early ready receipt rejected")
	}
	miss := &protocol.PrefixCacheLookupMessage{
		RequestID: "request", CacheReceiptNonce: nonce,
		Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !tracker.applyLookup("provider", miss, now.Add(2*time.Second)) {
		t.Fatal("terminal lookup miss rejected")
	}
	hint, ok := tracker.hints(route, CacheRoutingConversation, now.Add(3*time.Second))["provider"]
	if !ok || hint.ReadyTokens != 768 {
		t.Fatalf("ready holder was removed by older lookup miss: %+v", hint)
	}
}

func TestCacheReadyDoesNotRegressAcrossAttempts(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(175, 0)
	route := CacheRoute{ExactKey: "exact", ConversationKey: "conversation", ConversationKind: "explicit"}
	nonceA, _ := tracker.registerAttempt("request-a", "provider", "model", route, now)
	nonceB, _ := tracker.registerAttempt("request-b", "provider", "model", route, now)
	ready := func(requestID, nonce string, tokens int, at time.Time) bool {
		return tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
			RequestID: requestID, CacheReceiptNonce: nonce, ReadyTokens: tokens,
			RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: tokens - 100, Tier: "ssd",
		}, at)
	}
	if !ready("request-a", nonceA, 1000, now.Add(time.Second)) ||
		!ready("request-b", nonceB, 2000, now.Add(2*time.Second)) ||
		!ready("request-a", nonceA, 1500, now.Add(3*time.Second)) {
		t.Fatal("valid interleaved ready receipt rejected")
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	for _, key := range []string{route.ExactKey, route.ConversationKey} {
		holder := tracker.holders[key]["provider"]
		if holder.ReadyTokens != 2000 || holder.RequiredRecomputeTokens != 100 {
			t.Fatalf("cross-attempt ready regressed holder for %q: %+v", key, holder)
		}
	}
}

func TestCacheReadyUpdatesEachKeyIndependently(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(180, 0)
	routeA := CacheRoute{ExactKey: "shared-exact", ConversationKey: "conversation"}
	routeB := CacheRoute{ExactKey: "shared-exact"}
	nonceA, _ := tracker.registerAttempt("request-a", "provider", "model", routeA, now)
	nonceB, _ := tracker.registerAttempt("request-b", "provider", "model", routeB, now)
	ready := func(requestID, nonce string, tokens int, at time.Time) bool {
		return tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
			RequestID: requestID, CacheReceiptNonce: nonce, ReadyTokens: tokens,
			RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: tokens - 100, Tier: "ssd",
		}, at)
	}
	if !ready("request-a", nonceA, 1000, now.Add(time.Second)) ||
		!ready("request-b", nonceB, 2000, now.Add(2*time.Second)) ||
		!ready("request-a", nonceA, 1500, now.Add(3*time.Second)) {
		t.Fatal("valid interleaved ready receipt rejected")
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if got := tracker.holders[routeA.ExactKey]["provider"].ReadyTokens; got != 2000 {
		t.Fatalf("shared exact holder regressed to %d", got)
	}
	if got := tracker.holders[routeA.ConversationKey]["provider"].ReadyTokens; got != 1500 {
		t.Fatalf("independent conversation holder = %d, want 1500", got)
	}
}

func TestOlderCacheLookupCannotRegressNewerAttemptEvidence(t *testing.T) {
	for _, outcome := range []string{"miss_absent", "miss_corrupt", "skipped_capacity"} {
		t.Run(outcome, func(t *testing.T) {
			tracker := newCacheRoutingTracker(time.Minute, 4)
			now := time.Unix(185, 0)
			route := CacheRoute{ExactKey: "exact", ConversationKey: "conversation"}
			olderNonce, _ := tracker.registerAttempt("older", "provider", "model", route, now)
			newerNonce, _ := tracker.registerAttempt("newer", "provider", "model", route, now.Add(time.Second))
			if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
				RequestID: "newer", CacheReceiptNonce: newerNonce, ReadyTokens: 1000,
				RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
			}, now.Add(2*time.Second)) {
				t.Fatal("newer ready receipt rejected")
			}
			if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
				RequestID: "older", CacheReceiptNonce: olderNonce, Outcome: outcome,
			}, now.Add(3*time.Second)) {
				t.Fatal("valid delayed older lookup rejected")
			}
			hints := tracker.hints(route, CacheRoutingConversation, now.Add(4*time.Second))
			if len(hints) != 1 || hints["provider"].ReadyTokens != 1000 {
				t.Fatalf("older %s regressed newer holder: %+v", outcome, hints)
			}
		})
	}
}

func TestNewerEqualReadyAdvancesEvidenceSequence(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(186, 0)
	route := CacheRoute{ExactKey: "exact"}
	firstNonce, _ := tracker.registerAttempt("first", "provider", "model", route, now)
	if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "first", CacheReceiptNonce: firstNonce, ReadyTokens: 1000,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
	}, now.Add(time.Second)) {
		t.Fatal("first ready rejected")
	}
	delayedNonce, _ := tracker.registerAttempt("delayed", "provider", "model", route, now.Add(2*time.Second))
	newestNonce, _ := tracker.registerAttempt("newest", "provider", "model", route, now.Add(3*time.Second))
	if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "newest", CacheReceiptNonce: newestNonce, ReadyTokens: 1000,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
	}, now.Add(4*time.Second)) {
		t.Fatal("equal newer ready rejected")
	}
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "delayed", CacheReceiptNonce: delayedNonce, Outcome: "miss_absent",
	}, now.Add(5*time.Second)) {
		t.Fatal("delayed miss rejected")
	}
	if hint := tracker.hints(route, CacheRoutingExact, now.Add(6*time.Second))["provider"]; hint.ReadyTokens != 1000 {
		t.Fatalf("delayed miss regressed equal newer ready: %+v", hint)
	}
}

func TestOlderLongerReadyDoesNotLowerEvidenceSequence(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(187, 0)
	route := CacheRoute{ExactKey: "exact"}
	oldestNonce, _ := tracker.registerAttempt("oldest", "provider", "model", route, now)
	delayedNonce, _ := tracker.registerAttempt("delayed", "provider", "model", route, now.Add(time.Second))
	newestNonce, _ := tracker.registerAttempt("newest", "provider", "model", route, now.Add(2*time.Second))
	ready := func(requestID, nonce string, tokens int, at time.Time) bool {
		return tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
			RequestID: requestID, CacheReceiptNonce: nonce, ReadyTokens: tokens,
			RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: tokens - 100, Tier: "ssd",
		}, at)
	}
	if !ready("newest", newestNonce, 1000, now.Add(3*time.Second)) ||
		!ready("oldest", oldestNonce, 1500, now.Add(4*time.Second)) {
		t.Fatal("valid interleaved ready rejected")
	}
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "delayed", CacheReceiptNonce: delayedNonce, Outcome: "miss_absent",
	}, now.Add(5*time.Second)) {
		t.Fatal("delayed miss rejected")
	}
	if hint := tracker.hints(route, CacheRoutingExact, now.Add(6*time.Second))["provider"]; hint.ReadyTokens != 1500 {
		t.Fatalf("older longer ready lowered evidence ordering: %+v", hint)
	}
}

func TestSameAttemptReadyOutranksDelayedCapacityFeedback(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(189, 0)
	route := CacheRoute{ExactKey: "exact"}
	nonce, _ := tracker.registerAttempt("request", "provider", "model", route, now)
	if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "request", CacheReceiptNonce: nonce, ReadyTokens: 1000,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
	}, now.Add(time.Second)) {
		t.Fatal("ready rejected")
	}
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "request", CacheReceiptNonce: nonce, Outcome: "skipped_capacity",
	}, now.Add(2*time.Second)) {
		t.Fatal("capacity feedback rejected")
	}
	if hint := tracker.hints(route, CacheRoutingExact, now.Add(3*time.Second))["provider"]; hint.ReadyTokens != 1000 {
		t.Fatalf("delayed capacity feedback suppressed same-attempt ready: %+v", hint)
	}
}

func TestSameAttemptReadyClearsEarlierCapacitySuppression(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(190, 0)
	route := CacheRoute{ExactKey: "exact"}
	tracker.upsertForTest(route.ExactKey, "provider", now, 1000)
	nonce, _ := tracker.registerAttempt("request", "provider", "model", route, now)
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "request", CacheReceiptNonce: nonce, Outcome: "skipped_capacity",
	}, now.Add(time.Second)) {
		t.Fatal("capacity feedback rejected")
	}
	if hints := tracker.hints(route, CacheRoutingExact, now.Add(2*time.Second)); len(hints) != 0 {
		t.Fatalf("capacity suppression did not apply: %+v", hints)
	}
	if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "request", CacheReceiptNonce: nonce, ReadyTokens: 1000,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
	}, now.Add(3*time.Second)) {
		t.Fatal("ready rejected")
	}
	if hint := tracker.hints(route, CacheRoutingExact, now.Add(4*time.Second))["provider"]; hint.ReadyTokens != 1000 {
		t.Fatalf("ready did not clear same-attempt capacity suppression: %+v", hint)
	}
}

func TestOlderReadyCannotClearNewerCapacitySuppression(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(191, 0)
	route := CacheRoute{ExactKey: "exact"}
	olderNonce, _ := tracker.registerAttempt("older", "provider", "model", route, now)
	if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "older", CacheReceiptNonce: olderNonce, ReadyTokens: 1000,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
	}, now) {
		t.Fatal("older ready rejected")
	}
	newerNonce, _ := tracker.registerAttempt("newer", "provider", "model", route, now.Add(time.Second))
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "newer", CacheReceiptNonce: newerNonce, Outcome: "skipped_capacity",
	}, now.Add(2*time.Second)) {
		t.Fatal("newer capacity feedback rejected")
	}
	if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "older", CacheReceiptNonce: olderNonce, ReadyTokens: 1500,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 1400, Tier: "ssd",
	}, now.Add(3*time.Second)) {
		t.Fatal("older ready extension rejected")
	}
	if hints := tracker.hints(route, CacheRoutingExact, now.Add(4*time.Second)); len(hints) != 0 {
		t.Fatalf("older ready cleared newer capacity suppression: %+v", hints)
	}
	tracker.mu.Lock()
	holder := tracker.holders[route.ExactKey]["provider"]
	newerSequence := tracker.attempts[newerNonce].Sequence
	watermark := tracker.watermarks[cacheHolderRef{key: route.ExactKey, providerID: "provider"}]
	tracker.mu.Unlock()
	if holder.ReadyTokens != 1500 || holder.EvidenceSequence != newerSequence || holder.SuppressedUntil.IsZero() || watermark.Sequence != newerSequence {
		t.Fatalf("older physical extension regressed newer negative ordering: holder=%+v watermark=%+v newer_sequence=%d", holder, watermark, newerSequence)
	}
}

func TestEqualNewerReadyRefreshesHolderLifetime(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(192, 0)
	route := CacheRoute{ExactKey: "exact"}
	firstNonce, _ := tracker.registerAttempt("first", "provider", "model", route, now)
	ready := func(requestID, nonce string, at time.Time) bool {
		return tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
			RequestID: requestID, CacheReceiptNonce: nonce, ReadyTokens: 1000,
			RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
		}, at)
	}
	if !ready("first", firstNonce, now) {
		t.Fatal("first ready rejected")
	}
	refreshAt := now.Add(59 * time.Second)
	newerNonce, _ := tracker.registerAttempt("newer", "provider", "model", route, refreshAt)
	if !ready("newer", newerNonce, refreshAt) {
		t.Fatal("equal newer ready rejected")
	}
	if hint := tracker.hints(route, CacheRoutingExact, now.Add(61*time.Second))["provider"]; hint.ReadyTokens != 1000 {
		t.Fatalf("equal newer ready did not refresh lifetime: %+v", hint)
	}
	tracker.mu.Lock()
	holder := tracker.holders[route.ExactKey]["provider"]
	tracker.mu.Unlock()
	if !holder.UpdatedAt.Equal(refreshAt) || !holder.ExpiresAt.Equal(refreshAt.Add(time.Minute)) {
		t.Fatalf("refreshed holder timestamps = updated %v expires %v", holder.UpdatedAt, holder.ExpiresAt)
	}
}

func TestCacheAttemptSequenceWrapClearsOldEvidence(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(191, 0)
	tracker.upsertForTest("old", "provider", now, 1000)
	oldNonce, _ := tracker.registerAttempt("old", "provider", "model", CacheRoute{ExactKey: "old"}, now)
	tracker.mu.Lock()
	tracker.advanceWatermarkLocked(cacheHolderRef{key: "old", providerID: "provider"}, 1, now)
	tracker.nextAttemptSequence = ^uint64(0)
	tracker.mu.Unlock()
	newNonce, _ := tracker.registerAttempt("new", "provider", "model", CacheRoute{ExactKey: "new"}, now.Add(time.Second))
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if len(tracker.holders) != 0 {
		t.Fatalf("sequence wrap retained old holders: %+v", tracker.holders)
	}
	if len(tracker.watermarks) != 0 || len(tracker.watermarkOrder) != 0 || len(tracker.watermarkOrderByRef) != 0 {
		t.Fatal("sequence wrap retained old evidence watermarks")
	}
	if _, retained := tracker.activeAttemptRefs[cacheHolderRef{key: "old", providerID: "provider"}]; retained || len(tracker.activeAttemptRefs) != 1 {
		t.Fatalf("sequence wrap retained old active-attempt refs: %+v", tracker.activeAttemptRefs)
	}
	if _, exists := tracker.attempts[oldNonce]; exists {
		t.Fatal("sequence wrap retained old attempt")
	}
	if attempt := tracker.attempts[newNonce]; attempt.Sequence != 1 || tracker.nextAttemptSequence != 1 {
		t.Fatalf("post-wrap sequence = attempt %d tracker %d, want 1", attempt.Sequence, tracker.nextAttemptSequence)
	}
}

func TestNewerCacheMissStillRemovesOlderEvidence(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(188, 0)
	route := CacheRoute{ExactKey: "exact"}
	olderNonce, _ := tracker.registerAttempt("older", "provider", "model", route, now)
	if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "older", CacheReceiptNonce: olderNonce, ReadyTokens: 1000,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
	}, now.Add(time.Second)) {
		t.Fatal("older ready receipt rejected")
	}
	newerNonce, _ := tracker.registerAttempt("newer", "provider", "model", route, now.Add(2*time.Second))
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "newer", CacheReceiptNonce: newerNonce, Outcome: "miss_absent",
	}, now.Add(3*time.Second)) {
		t.Fatal("newer miss rejected")
	}
	if hints := tracker.hints(route, CacheRoutingExact, now.Add(4*time.Second)); len(hints) != 0 {
		t.Fatalf("newer miss retained older evidence: %+v", hints)
	}
}

func TestCacheTrackerGatesSweepsAndChecksExpiryDirectly(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(190, 0)
	tracker.lastSweep = now
	tracker.upsertHolderLocked("expired", cacheHolder{ProviderID: "provider", ReadyTokens: 2000, PrefillTokensSaved: 1900, Confirmed: true, UpdatedAt: now, ExpiresAt: now})
	tracker.upsertHolderLocked("unrelated", cacheHolder{ProviderID: "provider", ReadyTokens: 2000, PrefillTokensSaved: 1900, Confirmed: true, UpdatedAt: now, ExpiresAt: now})
	tracker.storeAttemptLocked("ready-expired", cacheAttempt{RequestID: "ready", ProviderID: "provider", ExactKey: "expired", CreatedAt: now, ExpiresAt: now})
	tracker.storeAttemptLocked("lookup-expired", cacheAttempt{RequestID: "lookup", ProviderID: "provider", ExactKey: "expired", CreatedAt: now, ExpiresAt: now})
	tracker.storeAttemptLocked("unrelated-expired", cacheAttempt{RequestID: "unrelated", ProviderID: "provider", CreatedAt: now, ExpiresAt: now})

	if tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "ready", CacheReceiptNonce: "ready-expired", ReadyTokens: 1000,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
	}, now) {
		t.Fatal("ready receipt accepted at attempt expiry")
	}
	if tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "lookup", CacheReceiptNonce: "lookup-expired", Outcome: "miss_absent",
	}, now) {
		t.Fatal("lookup receipt accepted at attempt expiry")
	}
	if hints := tracker.hints(CacheRoute{ExactKey: "expired"}, CacheRoutingExact, now); len(hints) != 0 {
		t.Fatalf("expired holder returned between maintenance sweeps: %+v", hints)
	}

	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if _, exists := tracker.attempts["ready-expired"]; exists {
		t.Fatal("direct ready expiry check retained attempt")
	}
	if _, exists := tracker.attempts["lookup-expired"]; exists {
		t.Fatal("direct lookup expiry check retained attempt")
	}
	if _, exists := tracker.attempts["unrelated-expired"]; !exists {
		t.Fatal("time-gated maintenance unexpectedly swept unrelated attempt")
	}
	if _, exists := tracker.holders["unrelated"]; !exists {
		t.Fatal("time-gated maintenance unexpectedly swept unrelated holder")
	}
	if tracker.holderCount != 1 {
		t.Fatalf("holder count = %d, want 1 after direct expiry cleanup", tracker.holderCount)
	}
}

func TestExpiredCacheHolderCannotBlockFreshReady(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(195, 0)
	tracker.lastSweep = now
	tracker.upsertHolderLocked("exact", cacheHolder{ProviderID: "provider", ReadyTokens: 2000, PrefillTokensSaved: 1900, Confirmed: true, UpdatedAt: now, ExpiresAt: now})
	nonce, _ := tracker.registerAttempt("request", "provider", "model", CacheRoute{ExactKey: "exact"}, now)
	if !tracker.applyReady("provider", &protocol.PrefixCacheReadyMessage{
		RequestID: "request", CacheReceiptNonce: nonce, ReadyTokens: 1000,
		RequiredRecomputeTokens: 100, ExpectedPrefillTokensSaved: 900, Tier: "ssd",
	}, now) {
		t.Fatal("fresh ready receipt rejected behind expired larger holder")
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if holder := tracker.holders["exact"]["provider"]; holder.ReadyTokens != 1000 || tracker.holderCount != 1 {
		t.Fatalf("fresh holder = %+v count=%d, want 1000 tokens and count 1", holder, tracker.holderCount)
	}
}

func TestCacheReceiptValidationAndDisconnect(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(200, 0)
	route := CacheRoute{ExactKey: "exact"}
	nonce, _ := tracker.registerAttempt("request", "provider", "model", route, now)
	valid := &protocol.PrefixCacheLookupMessage{RequestID: "request", CacheReceiptNonce: nonce, Outcome: "hit", Tier: "memory", CachedTokens: 10, PrefillTokensSaved: 9}
	if tracker.applyLookup("other-connection", valid, now) {
		t.Fatal("receipt crossed provider connection boundary")
	}
	wrongRequest := *valid
	wrongRequest.RequestID = "other-request"
	if tracker.applyLookup("provider", &wrongRequest, now) {
		t.Fatal("receipt crossed request boundary")
	}
	bad := &protocol.PrefixCacheLookupMessage{RequestID: "request", CacheReceiptNonce: nonce, Outcome: "hit", Tier: "ssd", CachedTokens: 10, PrefillTokensSaved: 11}
	if tracker.applyLookup("provider", bad, now) {
		t.Fatal("invalid numeric receipt accepted")
	}
	good := &protocol.PrefixCacheLookupMessage{RequestID: "request", CacheReceiptNonce: nonce, Outcome: "hit", Tier: "memory", CachedTokens: 10, PrefillTokensSaved: 9}
	if !tracker.applyLookup("provider", good, now) {
		t.Fatal("valid receipt rejected after invalid receipt")
	}
	tracker.disconnect("provider")
	if len(tracker.hints(route, CacheRoutingExact, now)) != 0 || len(tracker.attempts) != 0 || len(tracker.watermarks) != 0 {
		t.Fatal("disconnect retained holder, attempt, or watermark")
	}
	if len(tracker.holderOrder) != 0 || len(tracker.holderOrderByRef) != 0 || len(tracker.attemptOrder) != 0 || len(tracker.attemptOrderByNonce) != 0 || len(tracker.watermarkOrder) != 0 || len(tracker.watermarkOrderByRef) != 0 || len(tracker.activeAttemptRefs) != 0 {
		t.Fatal("disconnect retained cap ordering metadata")
	}
}

func TestCacheEvidenceWatermarksRemainBounded(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	if tracker.maxWatermarks < 2*tracker.maxAttempts {
		t.Fatalf("default watermark cap %d cannot cover two keys for %d live attempts", tracker.maxWatermarks, tracker.maxAttempts)
	}
	tracker.maxWatermarks = 2
	now := time.Unix(225, 0)
	for i, key := range []string{"route-a", "route-b", "route-c"} {
		requestID := fmt.Sprintf("request-%d", i)
		nonce, _ := tracker.registerAttempt(requestID, "provider", "model", CacheRoute{ExactKey: key}, now.Add(time.Duration(i)*time.Second))
		if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
			RequestID: requestID, CacheReceiptNonce: nonce, Outcome: "miss_absent",
		}, now.Add(time.Duration(i)*time.Second)) {
			t.Fatalf("negative receipt %d rejected", i)
		}
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if len(tracker.watermarks) != 2 || len(tracker.watermarkOrder) != 2 || len(tracker.watermarkOrderByRef) != 2 {
		t.Fatalf("watermark cap mismatch: live=%d heap=%d index=%d", len(tracker.watermarks), len(tracker.watermarkOrder), len(tracker.watermarkOrderByRef))
	}
	if _, oldestRetained := tracker.watermarks[cacheHolderRef{key: "route-a", providerID: "provider"}]; oldestRetained {
		t.Fatal("watermark cap retained oldest evidence")
	}
}

func TestCacheWatermarkCapPreservesActiveDelayedAttempt(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	tracker.maxWatermarks = 2
	now := time.Unix(235, 0)
	protectedRoute := CacheRoute{ExactKey: "protected"}
	olderNonce, _ := tracker.registerAttempt("older", "provider", "model", protectedRoute, now)
	newerNonce, _ := tracker.registerAttempt("newer", "provider", "model", protectedRoute, now.Add(time.Second))
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "newer", CacheReceiptNonce: newerNonce, Outcome: "miss_absent",
	}, now.Add(2*time.Second)) {
		t.Fatal("newer negative receipt rejected")
	}
	tracker.forgetAttempt(newerNonce)

	for i, key := range []string{"completed-a", "completed-b"} {
		requestID := fmt.Sprintf("completed-%d", i)
		nonce, _ := tracker.registerAttempt(requestID, "provider", "model", CacheRoute{ExactKey: key}, now.Add(time.Duration(3+i)*time.Second))
		if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
			RequestID: requestID, CacheReceiptNonce: nonce, Outcome: "miss_absent",
		}, now.Add(time.Duration(3+i)*time.Second)) {
			t.Fatalf("completed tombstone %d rejected", i)
		}
		tracker.forgetAttempt(nonce)
	}

	protectedRef := cacheHolderRef{key: protectedRoute.ExactKey, providerID: "provider"}
	tracker.mu.Lock()
	_, retained := tracker.watermarks[protectedRef]
	bounded := len(tracker.watermarks) == tracker.maxWatermarks
	tracker.mu.Unlock()
	if !retained || !bounded {
		t.Fatalf("overflow evicted protected watermark or exceeded cap: retained=%t count=%d", retained, len(tracker.watermarks))
	}
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "older", CacheReceiptNonce: olderNonce, Outcome: "hit",
		Tier: "memory", CachedTokens: 100, PrefillTokensSaved: 90,
	}, now.Add(10*time.Second)) {
		t.Fatal("delayed older hit receipt rejected")
	}
	if hints := tracker.hints(protectedRoute, CacheRoutingExact, now.Add(11*time.Second)); len(hints) != 0 {
		t.Fatalf("delayed older hit resurrected evidence after cap churn: %+v", hints)
	}
	tracker.forgetAttempt(olderNonce)
	tracker.mu.Lock()
	_, stillActive := tracker.activeAttemptRefs[protectedRef]
	_, nowEvictable := tracker.watermarkOrderByRef[protectedRef]
	tracker.mu.Unlock()
	if stillActive || !nowEvictable {
		t.Fatalf("attempt removal did not release indexed protection: active=%t evictable=%t", stillActive, nowEvictable)
	}
}

func TestCacheWatermarkCapIndexedMetadataUnderChurn(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	tracker.maxWatermarks = 32
	now := time.Unix(238, 0)
	protectedRoute := CacheRoute{ExactKey: "protected"}
	olderNonce, _ := tracker.registerAttempt("older", "provider", "model", protectedRoute, now)
	newerNonce, _ := tracker.registerAttempt("newer", "provider", "model", protectedRoute, now.Add(time.Millisecond))
	if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
		RequestID: "newer", CacheReceiptNonce: newerNonce, Outcome: "miss_absent",
	}, now.Add(2*time.Millisecond)) {
		t.Fatal("protected tombstone rejected")
	}
	tracker.forgetAttempt(newerNonce)

	for i := 0; i < 5000; i++ {
		requestID := fmt.Sprintf("churn-%d", i)
		key := fmt.Sprintf("route-%d", i)
		at := now.Add(time.Duration(i+3) * time.Millisecond)
		nonce, _ := tracker.registerAttempt(requestID, "provider", "model", CacheRoute{ExactKey: key}, at)
		if !tracker.applyLookup("provider", &protocol.PrefixCacheLookupMessage{
			RequestID: requestID, CacheReceiptNonce: nonce, Outcome: "miss_absent",
		}, at) {
			t.Fatalf("churn receipt %d rejected", i)
		}
		tracker.forgetAttempt(nonce)
	}

	protectedRef := cacheHolderRef{key: protectedRoute.ExactKey, providerID: "provider"}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if len(tracker.watermarks) != tracker.maxWatermarks {
		t.Fatalf("watermarks=%d, want cap %d", len(tracker.watermarks), tracker.maxWatermarks)
	}
	if _, retained := tracker.watermarks[protectedRef]; !retained {
		t.Fatal("indexed cap churn evicted protected watermark")
	}
	if _, evictable := tracker.watermarkOrderByRef[protectedRef]; evictable {
		t.Fatal("protected watermark remained in eviction heap")
	}
	if state := tracker.activeAttemptRefs[protectedRef]; state == nil || len(state.order) != 1 || state.order[0].nonce != olderNonce {
		t.Fatalf("active-attempt protection metadata = %+v", state)
	}
	if len(tracker.watermarkOrder) != tracker.maxWatermarks-1 || len(tracker.watermarkOrderByRef) != len(tracker.watermarkOrder) {
		t.Fatalf("eviction metadata mismatch: heap=%d index=%d", len(tracker.watermarkOrder), len(tracker.watermarkOrderByRef))
	}
	for index, entry := range tracker.watermarkOrder {
		if entry.index != index || tracker.watermarkOrderByRef[entry.ref] != entry {
			t.Fatalf("eviction heap index %d is inconsistent: %+v", index, entry)
		}
	}
}

func TestCacheEvidenceWatermarkExpiresAfterReceiptWindow(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(240, 0)
	ref := cacheHolderRef{key: "route", providerID: "provider"}
	tracker.mu.Lock()
	tracker.advanceWatermarkLocked(ref, 1, now)
	tracker.sweepLocked(now.Add(cacheRoutingInFlightAttemptTTL))
	_, retained := tracker.watermarks[ref]
	tracker.mu.Unlock()
	if retained {
		t.Fatal("watermark survived the full delayed-receipt window")
	}
}

func TestCacheAttemptCapEvictsOldestWithStableTie(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	tracker.maxAttempts = 2
	now := time.Unix(250, 0)
	route := CacheRoute{ExactKey: "exact"}
	first, _ := tracker.registerAttempt("first", "provider", "model", route, now)
	second, _ := tracker.registerAttempt("second", "provider", "model", route, now.Add(time.Second))
	third, _ := tracker.registerAttempt("third", "provider", "model", route, now.Add(2*time.Second))

	tracker.mu.Lock()
	if _, exists := tracker.attempts[first]; exists {
		tracker.mu.Unlock()
		t.Fatal("attempt cap retained the oldest attempt")
	}
	if _, exists := tracker.attempts[second]; !exists {
		tracker.mu.Unlock()
		t.Fatal("attempt cap removed the second-newest attempt")
	}
	if _, exists := tracker.attempts[third]; !exists {
		tracker.mu.Unlock()
		t.Fatal("attempt cap removed the newest attempt")
	}
	if len(tracker.attemptOrder) != 2 || len(tracker.attemptOrderByNonce) != 2 {
		tracker.mu.Unlock()
		t.Fatal("attempt cap metadata did not match live attempts")
	}
	tracker.mu.Unlock()

	tied := newCacheRoutingTracker(time.Minute, 4)
	tied.maxAttempts = 2
	tied.mu.Lock()
	for _, nonce := range []string{"nonce-b", "nonce-a", "nonce-c"} {
		tied.storeAttemptLocked(nonce, cacheAttempt{CreatedAt: now, ExpiresAt: now.Add(time.Hour)})
	}
	tied.enforceAttemptCapLocked()
	_, retainedA := tied.attempts["nonce-a"]
	_, retainedB := tied.attempts["nonce-b"]
	_, retainedC := tied.attempts["nonce-c"]
	tied.mu.Unlock()
	if retainedA || !retainedB || !retainedC {
		t.Fatalf("attempt tie-break retained a=%t b=%t c=%t, want lexically oldest nonce-a evicted", retainedA, retainedB, retainedC)
	}
}

func TestCacheHolderCapTracksInterleavedUpdatesAndStableTie(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	tracker.maxEntries = 2
	now := time.Unix(275, 0)
	upsert := func(key string, at time.Time) {
		tracker.upsertHolderLocked(key, cacheHolder{ProviderID: "provider", ReadyTokens: 100, PrefillTokensSaved: 100, Confirmed: true, UpdatedAt: at, ExpiresAt: at.Add(time.Hour)})
	}

	tracker.mu.Lock()
	upsert("route-a", now)
	upsert("route-b", now.Add(time.Second))
	upsert("route-a", now.Add(2*time.Second))
	upsert("route-c", now.Add(3*time.Second))
	_, retainedA := tracker.holders["route-a"]
	_, retainedB := tracker.holders["route-b"]
	_, retainedC := tracker.holders["route-c"]
	metadataCount := len(tracker.holderOrder)
	tracker.mu.Unlock()
	if !retainedA || retainedB || !retainedC {
		t.Fatalf("interleaved holder update retained a=%t b=%t c=%t, want updated a and new c", retainedA, retainedB, retainedC)
	}
	if metadataCount != 2 {
		t.Fatalf("holder order entries = %d, want 2", metadataCount)
	}

	tied := newCacheRoutingTracker(time.Minute, 4)
	tied.maxEntries = 2
	tied.mu.Lock()
	tied.upsertHolderLocked("route-b", cacheHolder{ProviderID: "provider", UpdatedAt: now, ExpiresAt: now.Add(time.Hour)})
	tied.upsertHolderLocked("route-a", cacheHolder{ProviderID: "provider", UpdatedAt: now, ExpiresAt: now.Add(time.Hour)})
	tied.upsertHolderLocked("route-c", cacheHolder{ProviderID: "provider", UpdatedAt: now.Add(time.Second), ExpiresAt: now.Add(time.Hour)})
	_, retainedA = tied.holders["route-a"]
	_, retainedB = tied.holders["route-b"]
	_, retainedC = tied.holders["route-c"]
	tied.mu.Unlock()
	if retainedA || !retainedB || !retainedC {
		t.Fatalf("holder tie-break retained a=%t b=%t c=%t, want lexically oldest route-a evicted", retainedA, retainedB, retainedC)
	}
}

func TestCacheCapOrderMetadataRemainsBounded(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	now := time.Unix(290, 0)

	tracker.mu.Lock()
	for i := range 1000 {
		updatedAt := now.Add(time.Duration(i) * time.Millisecond)
		tracker.upsertHolderLocked("exact", cacheHolder{ProviderID: "provider", UpdatedAt: updatedAt, ExpiresAt: updatedAt.Add(time.Hour)})
	}
	if len(tracker.holderOrder) != 1 || len(tracker.holderOrderByRef) != 1 {
		tracker.mu.Unlock()
		t.Fatalf("holder updates grew metadata: heap=%d index=%d", len(tracker.holderOrder), len(tracker.holderOrderByRef))
	}
	tracker.mu.Unlock()

	nonce, _ := tracker.registerAttempt("request", "provider", "model", CacheRoute{ExactKey: "exact"}, now)
	for i := range 1000 {
		tracker.markAttemptTerminal(nonce, now.Add(time.Duration(i)*time.Millisecond))
	}
	tracker.mu.Lock()
	if len(tracker.attemptOrder) != 1 || len(tracker.attemptOrderByNonce) != 1 {
		tracker.mu.Unlock()
		t.Fatalf("attempt updates grew metadata: heap=%d index=%d", len(tracker.attemptOrder), len(tracker.attemptOrderByNonce))
	}
	tracker.mu.Unlock()

	tracker.forgetAttempt(nonce)
	tracker.mu.Lock()
	tracker.removeHolderLocked("exact", "provider")
	if len(tracker.holderOrder) != 0 || len(tracker.holderOrderByRef) != 0 || len(tracker.attemptOrder) != 0 || len(tracker.attemptOrderByNonce) != 0 || len(tracker.activeAttemptRefs) != 0 {
		tracker.mu.Unlock()
		t.Fatal("forget/remove retained cap ordering metadata")
	}
	tracker.upsertHolderLocked("expired", cacheHolder{ProviderID: "provider", UpdatedAt: now, ExpiresAt: now})
	tracker.storeAttemptLocked("expired", cacheAttempt{CreatedAt: now, ExpiresAt: now})
	tracker.sweepLocked(now)
	if len(tracker.holderOrder) != 0 || len(tracker.holderOrderByRef) != 0 || len(tracker.attemptOrder) != 0 || len(tracker.attemptOrderByNonce) != 0 || len(tracker.activeAttemptRefs) != 0 {
		tracker.mu.Unlock()
		t.Fatal("sweep retained expired cap ordering metadata")
	}
	tracker.mu.Unlock()
}

func TestCacheHolderConcurrentBoundedLifecycle(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	tracker.maxEntries = 4
	route := CacheRoute{ExactKey: "exact"}
	now := time.Unix(300, 0)
	var wg sync.WaitGroup
	for i := range 20 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			providerID := fmt.Sprintf("provider-%02d", i)
			nonce, err := tracker.registerAttempt(fmt.Sprintf("request-%02d", i), providerID, "model", route, now.Add(time.Duration(i)*time.Millisecond))
			if err != nil {
				t.Errorf("register: %v", err)
				return
			}
			if !tracker.applyLookup(providerID, &protocol.PrefixCacheLookupMessage{RequestID: fmt.Sprintf("request-%02d", i), CacheReceiptNonce: nonce, Outcome: "hit", Tier: "memory", CachedTokens: 128, PrefillTokensSaved: 120}, now.Add(time.Duration(i)*time.Millisecond)) {
				t.Errorf("lookup %d rejected", i)
			}
		}(i)
	}
	wg.Wait()
	tracker.mu.Lock()
	if got := len(tracker.holders[route.ExactKey]); got != 4 {
		tracker.mu.Unlock()
		t.Fatalf("holders=%d, want deterministic cap 4", got)
	}
	tracker.mu.Unlock()

	providerID := "provider-19"
	nonce, _ := tracker.registerAttempt("capacity", providerID, "model", route, now.Add(time.Second))
	if !tracker.applyLookup(providerID, &protocol.PrefixCacheLookupMessage{RequestID: "capacity", CacheReceiptNonce: nonce, Outcome: "skipped_capacity"}, now.Add(time.Second)) {
		t.Fatal("capacity receipt rejected")
	}
	if _, ok := tracker.hints(route, CacheRoutingExact, now.Add(2*time.Second))[providerID]; ok {
		t.Fatal("capacity-suppressed holder remained routable")
	}

	nonce, _ = tracker.registerAttempt("policy", providerID, "model", route, now.Add(3*time.Second))
	if !tracker.applyLookup(providerID, &protocol.PrefixCacheLookupMessage{RequestID: "policy", CacheReceiptNonce: nonce, Outcome: "skipped_policy"}, now.Add(3*time.Second)) {
		t.Fatal("policy receipt rejected")
	}
	tracker.mu.Lock()
	_, retained := tracker.holders[route.ExactKey][providerID]
	tracker.mu.Unlock()
	if !retained {
		t.Fatal("policy skip falsely removed holder")
	}

	nonce, _ = tracker.registerAttempt("absent", providerID, "model", route, now.Add(4*time.Second))
	if !tracker.applyLookup(providerID, &protocol.PrefixCacheLookupMessage{RequestID: "absent", CacheReceiptNonce: nonce, Outcome: "miss_absent"}, now.Add(4*time.Second)) {
		t.Fatal("absent receipt rejected")
	}
	tracker.mu.Lock()
	_, retained = tracker.holders[route.ExactKey][providerID]
	tracker.mu.Unlock()
	if retained {
		t.Fatal("absent receipt did not remove holder")
	}
}

func TestCacheRoutingDoesNotBypassCapacity(t *testing.T) {
	reg := New(testLogger())
	reg.cacheRoutingMode = CacheRoutingExact
	model := "cache-capacity"
	full := makeSchedulerProvider(t, reg, "full", model, 200)
	open := makeSchedulerProvider(t, reg, "open", model, 80)
	full.mu.Lock()
	full.BackendCapacity.Slots[0].MaxConcurrency = 1
	full.BackendCapacity.Slots[0].NumRunning = 1
	full.mu.Unlock()
	route := CacheRoute{ExactKey: "exact"}
	reg.cacheRouting.upsertForTest(route.ExactKey, full.ID, time.Now(), 4000)
	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "request", Model: model, EstimatedPromptTokens: 4000, RequestedMaxTokens: 128, CacheRoute: route})
	if selected == nil || selected.ID != open.ID {
		t.Fatalf("selected=%v decision=%+v, want open provider", selected, decision)
	}
}

func TestCacheRoutingAppliesBoundedExactDiscount(t *testing.T) {
	reg := New(testLogger())
	reg.cacheRoutingMode = CacheRoutingExact
	model := "cache-discount"
	provider := makeSchedulerProvider(t, reg, "provider", model, 100)
	route := CacheRoute{ExactKey: "exact", ConversationKey: "conversation", ConversationKind: "explicit"}
	reg.cacheRouting.upsertForTest(route.ExactKey, provider.ID, time.Now(), 4096)
	pr := &PendingRequest{RequestID: "request", Model: model, EstimatedPromptTokens: 4096, RequestedMaxTokens: 128, CacheRoute: route}
	selected, decision := reg.ReserveProviderEx(model, pr)
	if selected == nil || decision.CacheKind != "exact" || decision.CacheDiscountMs <= 0 || decision.CacheDiscountMs > 1000 || decision.CacheDiscountMs > (decision.CostMs+decision.CacheDiscountMs)*.35+1 {
		t.Fatalf("invalid exact discount: selected=%v decision=%+v", selected, decision)
	}
	if pr.CacheSelectionMode != "active" || pr.CacheSelectionKind != "exact" || pr.CacheSelectionTier != "memory" || !pr.CacheSelectionSelected || pr.CacheSelectionWouldChange || pr.CacheSelectionDiscountMs != decision.CacheDiscountMs {
		t.Fatalf("pending cache selection metadata = %+v", pr)
	}
}

func TestCacheRoutingModeControlsConversationHints(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 4)
	route := CacheRoute{ExactKey: "exact", ConversationKey: "conversation", ConversationKind: "derived"}
	tracker.upsertForTest(route.ConversationKey, "provider", time.Now(), 100)
	if _, ok := tracker.hints(route, CacheRoutingExact, time.Now())["provider"]; ok {
		t.Fatal("exact mode consumed conversation holder")
	}
	if hint := tracker.hints(route, CacheRoutingConversation, time.Now())["provider"]; hint.Kind != "conversation_derived" || hint.Confidence != .4 {
		t.Fatalf("conversation hint = %+v", hint)
	}
}

func TestCacheRoutingBusyHolderLosesToMateriallyFasterProvider(t *testing.T) {
	reg := New(testLogger())
	reg.cacheRoutingMode = CacheRoutingExact
	model := "cache-busy-loses"
	holder := makeSchedulerProvider(t, reg, "holder", model, 20)
	fast := makeSchedulerProvider(t, reg, "fast", model, 200)
	holder.mu.Lock()
	holder.BackendCapacity.Slots[0].NumRunning = 1
	holder.mu.Unlock()
	route := CacheRoute{ExactKey: "exact"}
	reg.cacheRouting.upsertForTest(route.ExactKey, holder.ID, time.Now(), 4096)
	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "request", Model: model, EstimatedPromptTokens: 4096, RequestedMaxTokens: 4096, CacheRoute: route})
	if selected == nil || selected.ID != fast.ID {
		t.Fatalf("selected=%v decision=%+v, want materially faster idle provider", selected, decision)
	}
}

func TestCacheRoutingObserveDoesNotChangeWinner(t *testing.T) {
	reg := New(testLogger())
	reg.cacheRoutingMode = CacheRoutingObserve
	model := "cache-observe"
	slow := makeSchedulerProvider(t, reg, "slow", model, 20)
	fast := makeSchedulerProvider(t, reg, "fast", model, 200)
	route := CacheRoute{ExactKey: "exact", ConversationKey: "conversation", ConversationKind: "explicit"}
	reg.cacheRouting.upsertForTest(route.ConversationKey, slow.ID, time.Now(), 4096)
	if hint := reg.cacheRouting.hints(route, CacheRoutingObserve, time.Now())[slow.ID]; hint.Kind != "conversation_explicit" {
		t.Fatalf("observe mode did not evaluate conversation hint: %+v", hint)
	}
	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "request", Model: model, EstimatedPromptTokens: 4096, RequestedMaxTokens: 4096, CacheRoute: route})
	if selected == nil || selected.ID != fast.ID {
		t.Fatalf("observe mode selected %v, want baseline provider %q", selected, fast.ID)
	}
	if decision.CacheWouldChange {
		t.Fatalf("slow cached provider falsely changed shadow winner: %+v", decision)
	}
}

func TestCacheRoutingObserveReportsChangedWinner(t *testing.T) {
	reg := New(testLogger())
	reg.cacheRoutingMode = CacheRoutingObserve
	model := "cache-observe-change"
	baseline := makeSchedulerProvider(t, reg, "baseline", model, 100)
	cached := makeSchedulerProvider(t, reg, "cached", model, 100)
	baseline.mu.Lock()
	baseline.BackendCapacity.Slots[0].NumRunning = 1
	baseline.mu.Unlock()
	cached.mu.Lock()
	cached.SystemMetrics.MemoryPressure = .9
	cached.SystemMetrics.CPUUsage = .9
	cached.SystemMetrics.ThermalState = "fair"
	cached.mu.Unlock()
	route := CacheRoute{ExactKey: "exact"}
	reg.cacheRouting.upsertForTest(route.ExactKey, cached.ID, time.Now(), 4096)

	pr := &PendingRequest{
		RequestID: "request", Model: model, EstimatedPromptTokens: 4096,
		RequestedMaxTokens: 128, CacheRoute: route,
	}
	selected, decision := reg.ReserveProviderEx(model, pr)
	if selected == nil || selected.ID != baseline.ID {
		t.Fatalf("observe mode selected %v, want baseline provider %q; decision=%+v", selected, baseline.ID, decision)
	}
	if !decision.CacheWouldChange || decision.CacheKind != "observe_exact" || decision.CacheDiscountMs <= 0 {
		t.Fatalf("cache discount did not change shadow winner: %+v", decision)
	}
	if pr.CacheSelectionMode != "observe" || pr.CacheSelectionKind != "exact" || pr.CacheSelectionSelected || !pr.CacheSelectionWouldChange || pr.CacheSelectionDiscountMs != decision.CacheDiscountMs {
		t.Fatalf("pending observe metadata = %+v", pr)
	}
}

func TestCacheObservationComparesAllEligibleCandidates(t *testing.T) {
	actual := &routingCandidate{costMs: 1000, effectiveQueue: 1}
	cached := &routingCandidate{costMs: 4500, effectiveQueue: 0}
	cached.breakdown.CacheDiscountMs = 1000
	actualCost, cachedCost := actual.costMs, cached.costMs
	if got := selectCacheObservationCandidate([]*routingCandidate{actual, cached}, actual); got != cached {
		t.Fatalf("shadow winner = %p, want discounted cached candidate %p", got, cached)
	}
	if actual.costMs != actualCost || cached.costMs != cachedCost {
		t.Fatalf("shadow selection mutated active costs: actual=%f cached=%f", actual.costMs, cached.costMs)
	}

	cached.costMs = 5000
	cached.effectiveQueue = 1
	actual.effectiveQueue = 0
	if got := selectCacheObservationCandidate([]*routingCandidate{actual, cached}, actual); got != actual {
		t.Fatalf("shadow winner = %p, want still-faster baseline candidate %p", got, actual)
	}
}

func (t *cacheRoutingTracker) upsertForTest(key, providerID string, now time.Time, tokens int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.upsertHolderLocked(key, cacheHolder{ProviderID: providerID, ReadyTokens: tokens, PrefillTokensSaved: tokens, Tier: "memory", Outcome: "ready", Confirmed: true, UpdatedAt: now, ExpiresAt: now.Add(t.ttl)})
}
