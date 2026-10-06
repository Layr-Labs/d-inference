package registry_test

import (
	"encoding/base64"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCacheOpportunityReasons(t *testing.T) {
	cases := []struct {
		o        production.CacheOpportunity
		selected bool
		want     string
	}{
		{production.CacheOpportunity{}, false, "not_evaluated"},
		{production.CacheOpportunity{Evaluated: true}, false, "no_repeat_observed"},
		{production.CacheOpportunity{Evaluated: true, RepeatedPrefixTokens: 256}, false, "repeat_without_holder"},
		{production.CacheOpportunity{Evaluated: true, MatchingHolders: 1}, false, "holder_evidence_unusable"},
		{production.CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1}, false, "holder_unavailable"},
		{production.CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1, CreditedCandidates: 1}, false, "holder_not_selected"},
		{production.CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1}, false, "holder_no_positive_credit"},
		{production.CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1}, true, "selected"},
	}
	for _, c := range cases {
		p := &production.PendingRequest{CacheOpportunity: c.o, CacheSelectionSelected: c.selected}
		if got := p.CacheOpportunityReason(); got != c.want {
			t.Fatalf("got %s want %s", got, c.want)
		}
	}
}

func TestCacheDemandCapIsIndependentOfHolderCaps(t *testing.T) {
	var demandLimit int
	var settings cachetracker.Settings
	production.NewWithDependencies(slog.New(slog.NewTextHandler(io.Discard, nil)), production.Dependencies{
		Cache: production.CacheDependencies{
			Demand: func(limit int, ttl time.Duration, index *cachehistory.Index) *cachedemand.Tracker {
				demandLimit = limit
				return cachedemand.New(limit, ttl, index)
			},
			Trackers: func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
				settings = config.Settings
				return cachetracker.New(config)
			},
		},
	})
	if demandLimit != cachedemand.MaxEntries {
		t.Fatalf("demand cap=%d, want %d", demandLimit, cachedemand.MaxEntries)
	}
	if settings.MaxEntries != 250_000 || settings.MaxAttempts != 50_000 {
		t.Fatalf("holder caps changed: entries=%d attempts=%d", settings.MaxEntries, settings.MaxAttempts)
	}
	if cachedemand.MaxEntries != 1_000_000 {
		t.Fatalf("demand cap %d changed; TestCacheDemandCapCoversMeasuredPlanMix holds its sizing", cachedemand.MaxEntries)
	}
}

// The demand index reports its size and the evictions that cost repeats.
func TestCacheDemandStatusCountsEntriesAndCapEvictions(t *testing.T) {
	const limit = 8
	var demand *cachedemand.Tracker
	var generation *cacheplan.Generation
	r := production.NewWithDependencies(slog.New(slog.NewTextHandler(io.Discard, nil)), production.Dependencies{
		Cache: production.CacheDependencies{
			DemandLimit: limit,
			Demand: func(limit int, ttl time.Duration, index *cachehistory.Index) *cachedemand.Tracker {
				demand = cachedemand.New(limit, ttl, index)
				return demand
			},
			Generations: func() *cacheplan.Generation {
				generation = &cacheplan.Generation{}
				return generation
			},
			Now: func() time.Time { return time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC) },
		},
	})
	master := []byte("0123456789abcdef0123456789abcdef")
	if err := r.ConfigureCacheRouting(production.CacheRoutingConfig{
		Mode: production.CacheRoutingOn, ActivationPct: 100, TTL: 25 * time.Minute,
		MaxHolders: 4, MasterKey: base64.RawURLEncoding.EncodeToString(master),
	}); err != nil {
		t.Fatal(err)
	}
	r.Register("0f6b3c1e-5a0d-4c58-9f7e-2b1d6a4c8e90", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{{
			ModelID: "model", ModelAggregateHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64),
			BlockHashVersion: promptcontract.BlockHashVersion, BlockSize: promptcontract.BlockSize,
			CacheEpoch: "11111111-1111-1111-1111-111111111111", Enabled: true, Ready: true,
		}},
	})
	status := func() (int, uint64) {
		lifecycle := r.CacheRoutingLifecycleStatus()
		return lifecycle.DemandEntries, lifecycle.DemandCapEvictions
	}
	if entries, evicted := status(); entries != 0 || evicted != 0 {
		t.Fatalf("fresh index: entries=%d cap evictions=%d", entries, evicted)
	}
	key := cacheactivation.HMACBytes(master, []byte("darkbloom/cache-routing/route/v3"))
	now := time.Unix(1_700_000_000, 0)
	observe := func(tokens int, variant uint32) int {
		plan := demandTestPlan(generation, tokens, 0, variant) // variants share nothing
		plan.ObserveRouteDemand(generation, demand, key, now)
		return plan.RepeatedPrefixTokens
	}
	observe(5_000, 1) // 1,024 ... 4,096 and the final 4,864
	if entries, evicted := status(); entries != 5 || evicted != 0 {
		t.Fatalf("one plan: entries=%d cap evictions=%d, want 5 and 0", entries, evicted)
	}
	observe(5_000, 1) // a repeat refreshes; it adds nothing
	if entries, evicted := status(); entries != 5 || evicted != 0 {
		t.Fatalf("repeat: entries=%d cap evictions=%d, want 5 and 0", entries, evicted)
	}
	now = now.Add(time.Minute)
	observe(5_000, 2) // five more into room for three: two live entries go
	if entries, evicted := status(); entries != limit || evicted != 2 {
		t.Fatalf("over the cap: entries=%d cap evictions=%d, want %d and 2", entries, evicted, limit)
	}
	// The evicted entries were the first plan's shallowest: it now repeats
	// from 3,072 up only, and the turnover is what the counter reports.
	if repeat := observe(5_000, 1); repeat != 4_864 {
		t.Fatalf("first plan after eviction repeats %d", repeat)
	}
	_, before := status()
	// Past the TTL the head is an expiry, not a cap eviction.
	now = now.Add(26 * time.Minute)
	observe(5_000, 3)
	entries, evicted := status()
	if entries != 5 || evicted != before {
		t.Fatalf("after the ttl: entries=%d cap evictions=%d, want 5 and %d", entries, evicted, before)
	}
}
