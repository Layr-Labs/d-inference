package registry

import (
	"fmt"
	"math/rand"
	"reflect"
	"testing"
	"time"
)

func assertCacheMatchParity(t testing.TB, f *cacheMatchFixture) {
	t.Helper()
	expected, expectedObservation := f.r.cacheRoutingHintsMaterializationReference("model", f.plan, f.tracker, f.key, CacheRoutingOn, f.now)
	actual, actualObservation := f.r.cacheRoutingHintsWithObservation("model", f.plan, f.tracker, f.key, CacheRoutingOn, f.now)
	if !reflect.DeepEqual(expected, actual) {
		t.Fatal("complete reference hint map differs")
	}
	if expectedObservation != actualObservation {
		t.Fatalf("opportunity differs: reference=%+v candidate=%+v", expectedObservation, actualObservation)
	}
	// Retained records may be fewer than the complete legacy snapshot.
	full := f.tracker.matchingHoldersMaterializationReference(f.plan, f.key, CacheRoutingOn, f.now)
	grouped := f.tracker.matchingHolders(f.plan, f.key, CacheRoutingOn, f.now)
	// Provider iteration inside each equal-depth bucket is intentionally unordered.
	// Query-wide fallback can begin at a different provider in a second snapshot,
	// changing only scratch record count; complete hints/opportunity remain exact.
	if len(grouped) > len(full) {
		t.Fatal("grouping invented reference records")
	}
}

func TestCacheMatchCompatibilityFallbacks(t *testing.T) {
	cases := []struct {
		name   string
		tiers  int
		mutate cacheMatchMutation
		after  func(*cacheMatchFixture)
	}{
		{name: "deepest", tiers: 1},
		{name: "stale-epoch", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				h.CacheEpoch = "stale"
			}
			return h
		}},
		{name: "old-pointer", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				h.Provider = &Provider{ID: h.ProviderID}
			}
			return h
		}},
		{name: "different-model", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				h.ModelID = "different-model"
			}
			return h
		}},
		{name: "old-measured-capability-expired", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				capability := f.capabilities[i]
				capability.CacheEpoch = "stale"
				h.stageMeasurement = &cacheStageMeasurement{milliseconds: 10, expiresAt: f.now.Add(-time.Second), capability: capability}
			}
			return h
		}},
		{name: "zero-deep-stage", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				h.StageMs = 0
			}
			return h
		}},
		{name: "negative-deep-stage", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				h.StageMs = -1
			}
			return h
		}},
		{name: "all-zero-stage-keeps-matching-count", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder { h.StageMs = 0; return h }},
		{name: "whole-anchor-recompute", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				h.RequiredRecomputeTokens = h.Anchor.TokenCount
			}
			return h
		}},
		{name: "expired-deep", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				h.ExpiresAt = f.now.Add(-time.Second)
			}
			return h
		}},
		{name: "wrong-deep-chain", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			if j == 7 {
				h.Anchor.ChainHash = "wrong"
			}
			return h
		}},
		{name: "persisted-empty-chain", tiers: 1, mutate: func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			h.Anchor.ChainHash = ""
			return h
		}},
		{name: "complete-ssd-before-memory", tiers: 2},
		{name: "unnegotiated-dual-tier", tiers: 2, after: func(f *cacheMatchFixture) {
			for _, p := range f.providers {
				c := p.PrefixCacheV2Models["model"]
				c.ReadyBoundaryMode = ""
				p.PrefixCacheV2Models["model"] = c
			}
		}},
		{name: "revoked-generation", tiers: 2, after: func(f *cacheMatchFixture) { f.tracker.generation.revoked.Store(true) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newCacheMatchFixture(8, 4, 4, c.tiers, true, c.mutate)
			if c.after != nil {
				c.after(f)
			}
			assertCacheMatchParity(t, f)
		})
	}
}

func TestCacheMatchRandomizedCompatibility(t *testing.T) {
	random := rand.New(rand.NewSource(20261003))
	for n := 0; n < 128; n++ {
		f := newCacheMatchFixture(32, 4, 4, 2, true, func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
			switch random.Intn(8) {
			case 0:
				h.CacheEpoch = "stale"
			case 1:
				h.Provider = &Provider{ID: h.ProviderID}
			case 2:
				h.ModelID = "different-model"
			case 3:
				capability := f.capabilities[i]
				capability.CacheEpoch = "stale"
				h.stageMeasurement = &cacheStageMeasurement{milliseconds: 10, expiresAt: f.now.Add(time.Second), capability: capability}
			case 4:
				h.StageMs = 0
			case 5:
				h.RequiredRecomputeTokens = h.Anchor.TokenCount
			case 6:
				h.ExpiresAt = f.now.Add(-time.Second)
			}
			return h
		})
		assertCacheMatchParity(t, f)
	}
}

func TestCacheMatchChurnBound(t *testing.T) {
	f := newCacheMatchFixture(208, 16, 16, 2, true, func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
		if j == 0 {
			return h
		}
		h.CacheEpoch = fmt.Sprintf("epoch-%d", j)
		if j%3 == 0 {
			h.Provider = &Provider{ID: h.ProviderID}
		}
		if j%5 == 0 {
			capability := f.capabilities[i]
			capability.CacheEpoch = fmt.Sprintf("measurement-%d", j)
			h.stageMeasurement = &cacheStageMeasurement{milliseconds: 120, expiresAt: f.now.Add(time.Hour), capability: capability}
		}
		return h
	})
	assertCacheMatchParity(t, f)
	hints, _ := f.r.cacheRoutingHintsWithObservation("model", f.plan, f.tracker, f.key, CacheRoutingOn, f.now)
	if len(hints) != 16 {
		t.Fatal("valid short fallback lost after group overflow")
	}
	for _, hint := range hints {
		if hint.CachedTokens != 256 {
			t.Fatal("wrong valid fallback after churn")
		}
	}
	full := f.tracker.matchingHoldersMaterializationReference(f.plan, f.key, CacheRoutingOn, f.now)
	groups := cacheMatchGroups{}
	retained := make([]cacheRoutingMatch, 0)
	for _, match := range full {
		if groups.retain(match, retained) {
			retained = append(retained, match)
		}
	}
	for _, group := range groups.byProvider {
		if len(group.indices) > cacheMatchMaxGroupsPerProvider {
			t.Fatal("unbounded group retention")
		}
	}
	if !groups.exhausted {
		t.Fatal("distinct churn must disable grouping")
	}
	if len(retained) != len(full) {
		t.Fatal("distinct churn must retain complete reference records")
	}
}

func TestCacheMatchProviderBudget(t *testing.T) {
	f := newCacheMatchFixture(32, 512, 512, 1, true, nil)
	assertCacheMatchParity(t, f)
	full := f.tracker.matchingHoldersMaterializationReference(f.plan, f.key, CacheRoutingOn, f.now)
	groups := cacheMatchGroups{}
	retained := make([]cacheRoutingMatch, 0)
	for _, match := range full {
		if groups.retain(match, retained) {
			retained = append(retained, match)
		}
	}
	if len(groups.byProvider) != cacheMatchMaxTrackedProviders {
		t.Fatal("provider budget not reached")
	}
	if len(retained) != len(full) {
		t.Fatal("all distinct providers must retain every reference record")
	}
}

func TestCacheMatchesRetainDeepestCompatibilityGroups(t *testing.T) {
	f := newCacheMatchFixture(208, 128, 16, 2, true, nil)
	matches := f.tracker.matchingHolders(f.plan, f.key, CacheRoutingOn, f.now)
	if len(matches) != 32 {
		t.Fatalf("retained %d matches; want one deepest endpoint per provider and tier (32)", len(matches))
	}
	for _, match := range matches {
		if match.Holder.Anchor.TokenCount != 208*256 {
			t.Fatalf("retained shorter endpoint %d", match.Holder.Anchor.TokenCount)
		}
	}
}

func TestCacheMatchMemoryOnlyAndQuarantine(t *testing.T) {
	t.Run("memory-only-zero-stage", func(t *testing.T) {
		f := newCacheMatchFixture(32, 4, 4, 2, true, nil)
		for _, provider := range f.providers {
			provider.PrefixCacheV2Models = nil
		}
		assertCacheMatchParity(t, f)
		hints, observation := f.r.cacheRoutingHintsWithObservation("model", f.plan, f.tracker, f.key, CacheRoutingOn, f.now)
		if observation.MatchingHolders != 4 || observation.ValidHolders != 4 {
			t.Fatalf("memory opportunity changed: %+v", observation)
		}
		for _, hint := range hints {
			if hint.Tier != "memory" || hint.StageMs != 0 || hint.CachedTokens != 32*256 {
				t.Fatalf("wrong deepest zero-stage memory endpoint: %+v", hint)
			}
		}
	})
	t.Run("quarantine-preserves-matching-count", func(t *testing.T) {
		f := newCacheMatchFixture(32, 4, 4, 2, true, nil)
		for i, provider := range f.providers {
			f.tracker.rejectCapability(provider.ID, "model", "ssd", f.capabilities[i], f.now)
		}
		assertCacheMatchParity(t, f)
		hints, observation := f.r.cacheRoutingHintsWithObservation("model", f.plan, f.tracker, f.key, CacheRoutingOn, f.now)
		if len(hints) != 0 || observation.MatchingHolders != 4 || observation.ValidHolders != 0 {
			t.Fatalf("quarantined SSD must retain observations and forbid memory fallback: %+v", observation)
		}
	})
}
