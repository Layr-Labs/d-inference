package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"
)

func TestOptionalCacheScoreLimits(t *testing.T) {
	for _, suffix := range []string{"MAX_DISCOUNT_MS", "MAX_COST_FRACTION"} {
		for _, raw := range []string{"", " ", "0", "0.25", "NaN", "Inf", "-1", "oops", "10001"} {
			t.Run(suffix+"="+raw, func(t *testing.T) {
				t.Setenv(env.EnvPrefix+"_CACHE_ROUTING_MODE", "off")
				t.Setenv(env.EnvPrefix+"_CACHE_ROUTING_MAX_DISCOUNT_MS", "")
				t.Setenv(env.EnvPrefix+"_CACHE_ROUTING_MAX_COST_FRACTION", "")
				t.Setenv(env.EnvPrefix+"_CACHE_ROUTING_"+suffix, raw)
				cfg := ReadConfig().CacheRouting
				value := cfg.MaxDiscountMs
				if suffix == "MAX_COST_FRACTION" {
					value = cfg.MaxCostFraction
				}
				if raw == "" || raw == " " {
					if value != nil || cfg.Check() != nil {
						t.Fatalf("absent limit was not optional: %+v", cfg)
					}
				} else if raw == "0" || raw == "0.25" {
					if value == nil || cfg.Check() != nil {
						t.Fatalf("numeric limit rejected: %+v", cfg)
					}
					if raw == "0" && *value != 0 {
						t.Fatal("explicit zero became an absent limit")
					}
				} else if cfg.Check() == nil {
					t.Fatalf("malformed limit %q accepted", raw)
				}
			})
		}
	}
}

func TestCacheScoreLimitsAreOwnedAcrossConfigurationReplacement(t *testing.T) {
	r := New(testLogger())
	cfg := CacheRoutingConfig{Mode: CacheRoutingOff, ActivationPct: 100, MaxHolders: 4,
		MaxDiscountMs: f64(1000), MaxCostFraction: f64(.35)}
	if err := r.ConfigureCacheRouting(cfg); err != nil {
		t.Fatal(err)
	}
	*cfg.MaxDiscountMs = 0
	*cfg.MaxCostFraction = 0
	got := r.CacheRoutingConfigSnapshot()
	if got.MaxDiscountMs == nil || *got.MaxDiscountMs != 1000 || *got.MaxCostFraction != .35 {
		t.Fatal("caller mutated active scoring limits")
	}
	*got.MaxDiscountMs = 0
	if *r.CacheRoutingConfigSnapshot().MaxDiscountMs != 1000 {
		t.Fatal("snapshot aliases registry limits")
	}
	cfg.MaxDiscountMs, cfg.MaxCostFraction = nil, nil
	if err := r.ConfigureCacheRouting(cfg); err != nil {
		t.Fatal(err)
	}
	got = r.CacheRoutingConfigSnapshot()
	if got.MaxDiscountMs != nil || got.MaxCostFraction != nil {
		t.Fatal("replacement retained old limits")
	}
}
