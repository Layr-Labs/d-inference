package api

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestLegacyProviderBodiesReceiveUniqueCacheBusters(t *testing.T) {
	reg := registry.New(quietLogger())
	if err := reg.ConfigureCacheRouting(registry.CacheRoutingConfig{
		Mode: registry.CacheRoutingConversation, TTL: time.Minute, MaxHolders: 4,
		MaxDiscountMs: 1000, MaxCostFraction: .35,
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		t.Fatal(err)
	}
	legacy := &registry.Provider{ID: "legacy", PrefixCacheProtocol: 0}
	bodies := map[string][]byte{
		"chat":        []byte(`{"model":"m","prompt_cache_key":"caller","seed":9007199254740993,"messages":[{"role":"user","content":"<hi>&"}]}`),
		"responses":   []byte(`{"model":"m","prompt_cache_key":"caller","input":"hi"}`),
		"anthropic":   []byte(`{"model":"m","prompt_cache_key":"caller","messages":[{"role":"user","content":"hi"}]}`),
		"completions": []byte(`{"model":"m","prompt_cache_key":"caller","prompt":"hi"}`),
		"generic":     []byte(`{"model":"m","prompt_cache_key":"caller","messages":[{"role":"user","content":"hi"}]}`),
	}
	seen := make(map[string]struct{}, len(bodies))
	for name, raw := range bodies {
		t.Run(name, func(t *testing.T) {
			original := append([]byte(nil), raw...)
			pr := &registry.PendingRequest{
				RequestID: "attempt-" + name, Attempt: len(seen), Model: "m", ConsumerKey: "account",
				CacheRoute: registry.CacheRoute{ExactKey: "exact-" + name, ScopeNamespace: "namespace"},
			}
			if err := reg.PrepareCacheAttempt(pr, legacy); err != nil {
				t.Fatal(err)
			}
			sealed, err := bodyForCacheAttempt(raw, false, legacy, pr)
			if err != nil {
				t.Fatal(err)
			}
			if string(raw) != string(original) {
				t.Fatal("caller-visible source body was mutated")
			}
			if name == "chat" && !strings.Contains(string(sealed), `"seed":9007199254740993`) {
				t.Fatalf("legacy isolation changed an exact JSON number: %s", sealed)
			}
			if name == "chat" && (!strings.Contains(string(sealed), `"content":"<hi>&"`) || strings.Contains(string(sealed), `\u003c`)) {
				t.Fatalf("legacy isolation HTML-escaped the provider body: %s", sealed)
			}
			var decoded map[string]any
			if err := json.Unmarshal(sealed, &decoded); err != nil {
				t.Fatal(err)
			}
			key, _ := decoded["prompt_cache_key"].(string)
			if key == "" || key == "caller" || key != pr.LegacyCacheBustKey {
				t.Fatalf("sealed prompt_cache_key = %q, prepared = %q", key, pr.LegacyCacheBustKey)
			}
			if _, duplicate := seen[key]; duplicate {
				t.Fatalf("legacy cache buster reused across attempts: %q", key)
			}
			seen[key] = struct{}{}
		})
	}
}

func TestProtocolV1BodyDoesNotReceiveLegacyCacheBuster(t *testing.T) {
	raw := []byte(`{"model":"m","prompt_cache_key":"caller","messages":[]}`)
	sealed, err := bodyForCacheAttempt(raw, false, &registry.Provider{PrefixCacheProtocol: 1}, &registry.PendingRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if string(sealed) != string(raw) {
		t.Fatalf("protocol-v1 body changed: %s", sealed)
	}
}

func TestCacheRoutingOffStillBustsLegacyProviderBody(t *testing.T) {
	reg := registry.New(quietLogger())
	legacy := &registry.Provider{ID: "legacy", PrefixCacheProtocol: 0}
	pr := &registry.PendingRequest{RequestID: "off-attempt", Model: "m", ConsumerKey: "account"}
	if err := reg.PrepareCacheAttempt(pr, legacy); err != nil {
		t.Fatal(err)
	}
	raw := []byte(`{"model":"m","prompt_cache_key":"caller","messages":[]}`)
	sealed, err := bodyForCacheAttempt(raw, false, legacy, pr)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(sealed, &decoded); err != nil {
		t.Fatal(err)
	}
	if got := decoded["prompt_cache_key"]; got != pr.LegacyCacheBustKey || got == "caller" {
		t.Fatalf("off-mode sealed prompt_cache_key = %v, prepared = %q", got, pr.LegacyCacheBustKey)
	}
}
