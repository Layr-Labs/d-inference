package registry

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"
)

type providerIndexFixture struct {
	t       *testing.T
	tracker *cacheRoutingTracker
	now     time.Time
}

func newProviderIndexFixture(t *testing.T) *providerIndexFixture {
	return &providerIndexFixture{
		t:       t,
		tracker: newCacheRoutingTracker(25*time.Minute, defaultCacheRoutingMaxHolders),
		now:     time.Unix(1_700_000_000, 0),
	}
}

// seed gives every provider one holder per model, tier and content key, one
// attempt per model and one sequence watermark per model and tier.
func (f *providerIndexFixture) seed(providers, models []string, contents int) {
	f.tracker.mu.Lock()
	defer f.tracker.mu.Unlock()
	for _, provider := range providers {
		for _, model := range models {
			for _, tier := range []string{"ssd", "memory"} {
				for content := 0; content < contents; content++ {
					key := cacheTierKey(fmt.Sprintf("%s-content-%d", model, content), tier)
					holder := sizingTestHolder(f.tracker, provider, tier, f.now)
					holder.ModelID = model
					f.tracker.upsertHolderLocked(key, holder)
				}
				f.tracker.v2Sequences[cacheV2SequenceKey{ProviderID: provider, ModelID: model, Tier: tier}] = 7
			}
			nonce := provider + "/" + model
			f.tracker.storeAttemptLocked(nonce, cacheAttempt{
				RequestID: nonce, ProviderID: provider, Model: model,
				CreatedAt: f.now, ExpiresAt: f.now.Add(cacheRoutingInFlightAttemptTTL),
			})
		}
	}
}

func (f *providerIndexFixture) count(provider, model string) (holders, attempts, sequences int) {
	f.tracker.mu.Lock()
	defer f.tracker.mu.Unlock()
	for _, bucket := range f.tracker.holders {
		if holder, ok := bucket[provider]; ok && holder.ModelID == model {
			holders++
		}
	}
	for _, attempt := range f.tracker.attempts {
		if attempt.ProviderID == provider && attempt.Model == model {
			attempts++
		}
	}
	for key := range f.tracker.v2Sequences {
		if key.ProviderID == provider && key.ModelID == model {
			sequences++
		}
	}
	return holders, attempts, sequences
}

func (f *providerIndexFixture) want(provider, model string, holders, attempts, sequences int) {
	f.t.Helper()
	if h, a, s := f.count(provider, model); h != holders || a != attempts || s != sequences {
		f.t.Fatalf("%s/%s: holders=%d attempts=%d sequences=%d, want %d/%d/%d",
			provider, model, h, a, s, holders, attempts, sequences)
	}
}

func TestCacheProviderInvalidationKeepsModelAndTierSemantics(t *testing.T) {
	const contents = 3
	f := newProviderIndexFixture(t)
	f.seed([]string{"p1", "p2", "p3"}, []string{"m1", "m2"}, contents)
	perModel := 2 * contents // both tiers
	assertCacheIndexInvariants(t, f.tracker, "seeded")

	// A model change drops that provider's model in both tiers and nothing else.
	f.tracker.invalidateProviderModels("p1", map[string]cacheHolderRemovalReason{
		"m1": cacheHolderRemovalEpochChange, "absent": cacheHolderRemovalCapabilityChange,
	})
	f.want("p1", "m1", 0, 0, 0)
	f.want("p1", "m2", perModel, 1, 2)
	f.want("p2", "m1", perModel, 1, 2)
	f.want("p3", "m2", perModel, 1, 2)
	assertCacheIndexInvariants(t, f.tracker, "model change")

	// A refresh re-keys the entry; it must not index the holder twice.
	f.tracker.mu.Lock()
	refreshed := sizingTestHolder(f.tracker, "p2", "ssd", f.now.Add(time.Minute))
	refreshed.ModelID = "m1"
	f.tracker.upsertHolderLocked(cacheTierKey("m1-content-0", "ssd"), refreshed)
	indexed := len(f.tracker.holdersByProvider["p2"])
	f.tracker.mu.Unlock()
	if indexed != 2*perModel {
		t.Fatalf("p2 indexes %d holders after a refresh, want %d", indexed, 2*perModel)
	}

	// A disconnect drops everything the provider has left.
	f.tracker.disconnect("p1", cacheHolderRemovalDisconnect)
	f.want("p1", "m2", 0, 0, 0)
	f.want("p2", "m1", perModel, 1, 2)
	f.want("p2", "m2", perModel, 1, 2)
	f.want("p3", "m1", perModel, 1, 2)
	assertCacheIndexInvariants(t, f.tracker, "disconnect")

	f.tracker.mu.Lock()
	_, holdersIndexed := f.tracker.holdersByProvider["p1"]
	_, attemptsIndexed := f.tracker.attemptsByProvider["p1"]
	epochChange := f.tracker.holderRemoved[string(cacheHolderRemovalEpochChange)]
	disconnect := f.tracker.holderRemoved[string(cacheHolderRemovalDisconnect)]
	capabilityChange := f.tracker.holderRemoved[string(cacheHolderRemovalCapabilityChange)]
	f.tracker.mu.Unlock()
	if holdersIndexed || attemptsIndexed {
		t.Fatal("a provider with nothing left kept an index entry")
	}
	if epochChange != uint64(perModel) || disconnect != uint64(perModel) || capabilityChange != 0 {
		t.Fatalf("removal reasons: epoch_change=%d disconnect=%d capability_change=%d, want %d/%d/0",
			epochChange, disconnect, capabilityChange, perModel, perModel)
	}

	// Unknown and empty providers are no-ops.
	f.tracker.disconnect("never-connected", cacheHolderRemovalDisconnect)
	f.tracker.disconnect("", cacheHolderRemovalDisconnect)
	f.tracker.invalidateProviderModels("p2", nil)
	f.want("p2", "m1", perModel, 1, 2)
	assertCacheIndexInvariants(t, f.tracker, "no-ops")
}

// Reconfiguration retires the tracker: its indexes are released with its
// maps, and late writes to it are dropped rather than re-indexed.
func TestCacheProviderIndexIsClearedOnReconfigure(t *testing.T) {
	h := newCacheSizingHarness(t, 25*time.Minute)
	for index := 0; index < 16; index++ {
		h.donate(index)
	}
	retired := h.r.cacheRouting
	assertCacheIndexInvariants(t, retired, "before reconfigure")
	// The demand index is the largest allocation a tracker owns; a prepared
	// attempt can keep the retired tracker reachable, so retirement must drop it.
	demandPlan := h.plan(7)
	retired.observeCacheDemand(&demandPlan, h.r.cacheRouteKeys.route, h.clock.Now())
	if entries, _ := retired.demand.stats(); entries == 0 {
		t.Fatal("demand index should hold the observed boundaries before reconfigure")
	}
	if err := h.r.ConfigureCacheRouting(CacheRoutingConfig{
		Mode: CacheRoutingOn, ActivationPct: 100, TTL: 25 * time.Minute,
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		t.Fatal(err)
	}
	retired.mu.Lock()
	retired.upsertHolderLocked("late", sizingTestHolder(retired, h.provider.ID, "ssd", h.clock.Now()))
	retired.storeAttemptLocked("late", cacheAttempt{ProviderID: h.provider.ID, ExpiresAt: h.clock.Now().Add(time.Hour)})
	cleared := retired.holdersByProvider == nil && retired.attemptsByProvider == nil &&
		retired.holderOrder == nil && retired.attemptOrder == nil && retired.holderCount == 0
	retired.mu.Unlock()
	if !cleared {
		t.Fatal("retired tracker kept index state")
	}
	if entries, _ := retired.demand.stats(); entries != 0 {
		t.Fatalf("retired tracker kept %d demand entries", entries)
	}
	retired.disconnect(h.provider.ID, cacheHolderRemovalDisconnect)
	retired.invalidateProviderModel(h.provider.ID, "model", cacheHolderRemovalCapabilityChange)
	assertCacheIndexInvariants(t, h.r.cacheRouting, "fresh tracker")
}

// The registry's own disconnect path reaches the index.
func TestCacheProviderDisconnectThroughRegistryDropsItsHolders(t *testing.T) {
	h := newCacheSizingHarness(t, 25*time.Minute)
	plans := make([]CachePlan, 32)
	for index := range plans {
		plans[index] = h.donate(index)
	}
	tracker := h.r.cacheRouting
	fillSyntheticHolders(tracker, 2_000, h.clock.Now())
	if holders, _ := h.r.CacheRoutingStateCounts(); holders != len(plans)+2_000 {
		t.Fatalf("seeded holders=%d", holders)
	}
	h.r.Disconnect(h.provider.ID)
	holders, attempts := h.r.CacheRoutingStateCounts()
	if holders != 2_000 || attempts != 0 {
		t.Fatalf("after disconnect holders=%d attempts=%d, want 2000/0", holders, attempts)
	}
	for _, plan := range plans {
		if matches := h.matches(plan, h.clock.Now()); len(matches) != 0 {
			t.Fatalf("disconnected provider still holds %+v", matches)
		}
	}
	if got := h.removed(cacheHolderRemovalDisconnect); got != uint64(len(plans)) {
		t.Fatalf("disconnect removals=%d want %d", got, len(plans))
	}
	assertCacheIndexInvariants(t, tracker, "registry disconnect")
}

// If the heaps and the maps ever drifted apart, cap enforcement must leave
// the index over its cap instead of indexing an empty heap.
func TestCacheCapEnforcementSurvivesIndexDrift(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, defaultCacheRoutingMaxHolders)
	now := time.Unix(1_700_000_000, 0)
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	tracker.maxEntries, tracker.maxAttempts = 1, 1
	tracker.holderCount = 5
	tracker.attempts["a"], tracker.attempts["b"] = cacheAttempt{}, cacheAttempt{}
	tracker.enforceCapLocked(now)
	tracker.enforceAttemptCapLocked()
	if backlog := tracker.sweepLocked(now); backlog {
		t.Fatal("empty heaps reported a sweep backlog")
	}
	if tracker.holderCount != 5 || len(tracker.attempts) != 2 {
		t.Fatalf("drifted state was rewritten: holders=%d attempts=%d", tracker.holderCount, len(tracker.attempts))
	}
}

func TestConfigureCacheRoutingWarnsAboveSizingTTL(t *testing.T) {
	for _, tc := range []struct {
		name string
		mode string
		ttl  time.Duration
		warn bool
	}{
		{"sized", CacheRoutingOn, cacheRoutingSizingTTL, false},
		{"default", CacheRoutingOn, 0, false},
		{"above", CacheRoutingOn, cacheRoutingSizingTTL + time.Second, true},
		{"above_but_off", CacheRoutingOff, 2 * time.Hour, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var logs bytes.Buffer
			r := New(slog.New(slog.NewTextHandler(&logs, nil)))
			err := r.ConfigureCacheRouting(CacheRoutingConfig{
				Mode: tc.mode, ActivationPct: 100, TTL: tc.ttl,
				MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
			})
			if err != nil {
				t.Fatalf("a long ttl must not refuse to start: %v", err)
			}
			warned := strings.Contains(logs.String(), "level=WARN") &&
				strings.Contains(logs.String(), "cache routing ttl exceeds")
			if warned != tc.warn {
				t.Fatalf("warned=%v want %v: %s", warned, tc.warn, logs.String())
			}
			if tc.warn && (!strings.Contains(logs.String(), "sized_for="+cacheRoutingSizingTTL.String()) ||
				!strings.Contains(logs.String(), fmt.Sprintf("demand_entries=%d", cacheDemandMaxEntries))) {
				t.Fatalf("warning lacks the sizing facts: %s", logs.String())
			}
			if want := tc.ttl; want != 0 && r.CacheRoutingConfigSnapshot().TTL != want {
				t.Fatalf("ttl=%s was not applied as configured", r.CacheRoutingConfigSnapshot().TTL)
			}
		})
	}
}
