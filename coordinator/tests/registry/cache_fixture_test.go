package registry_test

import (
	"encoding/base64"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func generationTestConfig(mode string) production.CacheRoutingConfig {
	return production.CacheRoutingConfig{Mode: mode, ActivationPct: 100, MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))}
}

func exactTestRegistry(t *testing.T, dependencies ...production.Dependencies) (*production.Registry, *production.Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	var deps production.Dependencies
	if len(dependencies) != 0 {
		deps = dependencies[0]
	}
	r := production.NewWithDependencies(testLogger(), deps)
	maxDiscount, maxCostFraction := 1000.0, .35
	err := r.ConfigureCacheRouting(production.CacheRoutingConfig{
		Mode: production.CacheRoutingOn, ActivationPct: 100, TTL: time.Minute, MaxHolders: 8,
		MaxDiscountMs: &maxDiscount, MaxCostFraction: &maxCostFraction,
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
	})
	if err != nil {
		t.Fatal(err)
	}
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	provider := r.Register("provider-a", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
	})
	return r, provider, capability
}
