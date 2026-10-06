package registry_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const firstSightMinTokensEnv = env.EnvPrefix + "_CACHE_ROUTING_FIRST_SIGHT_MIN_TOKENS"

func TestReadConfigCacheRoutingFirstSightDefaultsToOneStride(t *testing.T) {
	for _, unset := range []string{"", "  "} {
		t.Setenv(firstSightMinTokensEnv, unset)
		cfg := production.ReadConfig().CacheRouting
		if cfg.FirstSightMinTokens != 1_024 {
			t.Fatalf("%q read as %d, want the 1,024-token default", unset, cfg.FirstSightMinTokens)
		}
		if err := cfg.Check(); err != nil {
			t.Fatalf("default configuration rejected: %v", err)
		}
	}
}

// The default belongs to the environment loader. A configuration built as a
// literal leaves first sight off unless it names a minimum.
func TestCacheRoutingConfigLiteralLeavesFirstSightOff(t *testing.T) {
	r := production.New(testLogger())
	if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
		t.Fatal(err)
	}
	if got := r.CacheRoutingConfigSnapshot().FirstSightMinTokens; got != 0 {
		t.Fatalf("literal without a minimum configured first sight at %d tokens", got)
	}
}

func TestReadConfigCacheRoutingFirstSightAcceptsZeroAndTheTokenRange(t *testing.T) {
	for value, want := range map[string]int{"0": 0, "1024": 1_024, " 4096 ": 4_096, "1048576": 1_048_576} {
		t.Setenv(firstSightMinTokensEnv, value)
		cfg := production.ReadConfig().CacheRouting
		if cfg.FirstSightMinTokens != want {
			t.Fatalf("%q read as %d, want %d", value, cfg.FirstSightMinTokens, want)
		}
		if err := cfg.Check(); err != nil {
			t.Fatalf("%q rejected: %v", value, err)
		}
	}
}

// Check runs whatever the routing mode, so an invalid minimum stops startup
// even while cache routing is off.
func TestReadConfigCacheRoutingFirstSightRejectsInvalidValues(t *testing.T) {
	for _, mode := range []string{"", production.CacheRoutingOff} {
		t.Setenv(env.EnvPrefix+"_CACHE_ROUTING_MODE", mode)
		for _, value := range []string{"not-a-number", "4096.5", "-1", "1", "1023", "1048577"} {
			t.Setenv(firstSightMinTokensEnv, value)
			cfg := production.ReadConfig().CacheRouting
			if err := cfg.Check(); err == nil || !strings.Contains(err.Error(), "first sight min tokens") {
				t.Fatalf("mode %q, %q read as %d: check returned %v, want a first sight error", mode, value, cfg.FirstSightMinTokens, err)
			}
		}
	}
}

func TestCacheRoutingConfigAppliesFirstSightMinTokens(t *testing.T) {
	r := production.New(testLogger())
	config := generationTestConfig(production.CacheRoutingOn)
	config.TTL, config.MaxHolders = time.Minute, 4
	if got := r.CacheRoutingConfigSnapshot().FirstSightMinTokens; got != 0 {
		t.Fatalf("unconfigured registry reports first sight min tokens %d", got)
	}
	config.FirstSightMinTokens = 1_023
	if err := r.ConfigureCacheRouting(config); err == nil {
		t.Fatal("a minimum below one stride was applied")
	}
	config.FirstSightMinTokens = 4_096
	if err := r.ConfigureCacheRouting(config); err != nil {
		t.Fatal(err)
	}
	if got := r.CacheRoutingConfigSnapshot().FirstSightMinTokens; got != 4_096 {
		t.Fatalf("first sight min tokens = %d after configuring 4,096", got)
	}
}
