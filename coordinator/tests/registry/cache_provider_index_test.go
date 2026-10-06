package registry_test

import (
	"encoding/base64"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type providerIndexFixture struct {
	t       *testing.T
	tracker *cacheIndexKernelFixture
	now     time.Time
}

func newProviderIndexFixture(t *testing.T) *providerIndexFixture {
	return &providerIndexFixture{
		t:       t,
		tracker: newCacheIndexKernelFixture(cachetracker.Settings{TTL: 25 * time.Minute, MaxHolders: indexKernelMaxHolders, MaxEntries: indexKernelMaxEntries, MaxAttempts: indexKernelMaxAttempts}),
		now:     time.Unix(1_700_000_000, 0),
	}
}

// seed gives every provider one holder per model, tier and content key, one
// attempt per model and one sequence watermark per model and tier.
func (f *providerIndexFixture) seed(providers, models []string, contents int) {
	for _, provider := range providers {
		for _, model := range models {
			for _, tier := range []string{"ssd", "memory"} {
				for content := 0; content < contents; content++ {
					key := cachetracker.CacheTierKey(fmt.Sprintf("%s-content-%d", model, content), tier)
					holder := indexKernelTestHolder(f.tracker, provider, tier, f.now)
					holder.ModelID = model
					f.tracker.UpsertHolderLocked(key, holder)
				}
				f.tracker.config.Sequences.Store(cachetracker.SequenceKey{ProviderID: provider, ModelID: model, Tier: tier}, 7)
			}
			nonce := provider + "/" + model
			f.tracker.StoreAttemptLocked(nonce, indexKernelAttempt{
				RequestID: nonce, ProviderID: provider, Model: model,
				CreatedAt: f.now, ExpiresAt: f.now.Add(indexKernelInFlightAttemptTTL),
			})
		}
	}
}

func (f *providerIndexFixture) count(provider, model string) (holders, attempts, sequences int) {
	for _, bucket := range f.tracker.config.Holders.Buckets() {
		if holder, ok := bucket.Load(provider); ok && holder.ModelID == model {
			holders++
		}
	}
	for _, attempt := range f.tracker.config.Attempts.Entries() {
		if attempt.ProviderID == provider && attempt.Model == model {
			attempts++
		}
	}
	for key := range f.tracker.config.Sequences.Entries() {
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
	f.tracker.InvalidateProviderModels("p1", map[string]cachetracker.RemovalReason{
		"m1": cachetracker.RemovalEpochChange, "absent": cachetracker.RemovalCapabilityChange,
	})
	f.want("p1", "m1", 0, 0, 0)
	f.want("p1", "m2", perModel, 1, 2)
	f.want("p2", "m1", perModel, 1, 2)
	f.want("p3", "m2", perModel, 1, 2)
	assertCacheIndexInvariants(t, f.tracker, "model change")

	// A refresh re-keys the entry; it must not index the holder twice.
	refreshed := indexKernelTestHolder(f.tracker, "p2", "ssd", f.now.Add(time.Minute))
	refreshed.ModelID = "m1"
	f.tracker.UpsertHolderLocked(cachetracker.CacheTierKey("m1-content-0", "ssd"), refreshed)
	indexed := f.tracker.config.HolderProviders.Count("p2")
	if indexed != 2*perModel {
		t.Fatalf("p2 indexes %d holders after a refresh, want %d", indexed, 2*perModel)
	}

	// A disconnect drops everything the provider has left.
	f.tracker.InvalidateProviderEvidence("p1", cachetracker.RemovalDisconnect, false)
	f.want("p1", "m2", 0, 0, 0)
	f.want("p2", "m1", perModel, 1, 2)
	f.want("p2", "m2", perModel, 1, 2)
	f.want("p3", "m1", perModel, 1, 2)
	assertCacheIndexInvariants(t, f.tracker, "disconnect")

	holdersIndexed := f.tracker.config.HolderProviders.HasProvider("p1")
	attemptsIndexed := f.tracker.config.AttemptProviders.HasProvider("p1")
	epochChange := indexKernelMetrics(f.tracker).Removed[string(cachetracker.RemovalEpochChange)]
	disconnect := indexKernelMetrics(f.tracker).Removed[string(cachetracker.RemovalDisconnect)]
	capabilityChange := indexKernelMetrics(f.tracker).Removed[string(cachetracker.RemovalCapabilityChange)]
	if holdersIndexed || attemptsIndexed {
		t.Fatal("a provider with nothing left kept an index entry")
	}
	if epochChange != uint64(perModel) || disconnect != uint64(perModel) || capabilityChange != 0 {
		t.Fatalf("removal reasons: epoch_change=%d disconnect=%d capability_change=%d, want %d/%d/0",
			epochChange, disconnect, capabilityChange, perModel, perModel)
	}

	// Unknown and empty providers are no-ops.
	f.tracker.InvalidateProviderEvidence("never-connected", cachetracker.RemovalDisconnect, false)
	f.tracker.InvalidateProviderEvidence("", cachetracker.RemovalDisconnect, false)
	f.tracker.InvalidateProviderModels("p2", nil)
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
	retired, retiredDemand, retiredDemandIndex := h.tracker, h.demand, h.demandIndex
	assertCacheIndexInvariants(t, retired, "before reconfigure")
	// The demand index is the largest allocation a tracker owns; a prepared
	// attempt can keep the retired tracker reachable, so retirement must drop it.
	demandPlan := h.plan(7)
	demandPlan.ObserveRouteDemand(retired.config.Generation, retiredDemand, h.routeKey, h.clock.Now())
	if entries := retiredDemandIndex.Len(); entries == 0 {
		t.Fatal("demand index should hold the observed boundaries before reconfigure")
	}
	if err := h.r.ConfigureCacheRouting(production.CacheRoutingConfig{
		Mode: production.CacheRoutingOn, ActivationPct: 100, TTL: 25 * time.Minute,
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		t.Fatal(err)
	}
	retired.UpsertHolderLocked("late", indexKernelTestHolder(retired, h.provider.ID, "ssd", h.clock.Now()))
	retired.StoreAttemptLocked("late", indexKernelAttempt{ProviderID: h.provider.ID, ExpiresAt: h.clock.Now().Add(time.Hour)})
	cleared := retired.config.HolderProviders.ProviderCount() == 0 && retired.config.AttemptProviders.ProviderCount() == 0 &&
		retired.config.HolderOrder.Len() == 0 && retired.config.AttemptOrder.Len() == 0 && retired.config.Holders.Len() == 0
	if !cleared {
		t.Fatal("retired tracker kept index state")
	}
	if entries := retiredDemandIndex.Len(); entries != 0 {
		t.Fatalf("retired tracker kept %d demand entries", entries)
	}
	retired.InvalidateProviderEvidence(h.provider.ID, cachetracker.RemovalDisconnect, false)
	retired.InvalidateProviderModels(h.provider.ID, map[string]cachetracker.RemovalReason{"model": cachetracker.RemovalCapabilityChange})
	assertCacheIndexInvariants(t, h.tracker, "fresh tracker")
}

// The registry's own disconnect path reaches the index.
func TestCacheProviderDisconnectThroughRegistryDropsItsHolders(t *testing.T) {
	h := newCacheSizingHarness(t, 25*time.Minute)
	plans := make([]production.CachePlan, 32)
	for index := range plans {
		plans[index] = h.donate(index)
	}
	tracker := h.tracker
	fillIndexKernelHolders(tracker, 2_000, h.clock.Now())
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
	if got := h.removed(cachetracker.RemovalDisconnect); got != uint64(len(plans)) {
		t.Fatalf("disconnect removals=%d want %d", got, len(plans))
	}
	assertCacheIndexInvariants(t, tracker, "registry disconnect")
}
