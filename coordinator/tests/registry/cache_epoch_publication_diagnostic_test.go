package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Component witness, not a production workload or full SSD rehydration test.
// One model's epoch transition withdraws all its advertised prefix locations,
// including unrelated prefixes, while preserving another model's locations.
func TestDiagnosticCacheEpochFanout(t *testing.T) {
	r, _, a := budgetLifecycleRegistry(t)
	b := a
	b.ModelID = "other-model"
	// Replace the fixture connection by one that advertises both models through
	// the real registration path.
	r.Disconnect("provider-a")
	p := r.Register("fixture-provider", nil, &protocol.RegisterMessage{
		Models:              []protocol.ModelInfo{{ID: a.ModelID, WeightHash: a.ModelAggregateHash}, {ID: b.ModelID, WeightHash: b.ModelAggregateHash}},
		PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{a, b},
	})
	// The fixture retains the generation's actual tracker and holder directory.
	// Nothing else runs, so they are read and seeded directly.
	tracker := r.tracker()
	now := r.clock.Now()
	for _, capability := range []protocol.PrefixCacheV2Capability{a, b} {
		for i := 0; i < 64; i++ {
			tracker.core.UpsertHolderLocked(fmt.Sprintf("%s-prefix-%d", capability.ModelID, i), cachetracker.Holder[*production.Provider]{
				ProviderID: p.ID, ModelID: capability.ModelID, CacheEpoch: capability.CacheEpoch,
				UpdatedAt: now, ExpiresAt: now.Add(time.Minute)})
		}
	}
	a.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	removed := r.CacheRoutingLifecycleStatus().HolderRemoved[string(cachetracker.RemovalEpochChange)]
	if removed != 64 {
		t.Fatalf("epoch removed %d locations, want exactly the affected model's 64", removed)
	}
	holders := tracker.config.Holders
	if holders.Len() != 64 {
		t.Fatalf("retained holders=%d, want other model's 64", holders.Len())
	}
	for key, bucket := range holders.Buckets() {
		for _, holder := range bucket.Entries() {
			if holder.ModelID != b.ModelID {
				t.Fatalf("unexpected surviving holder at %s", key)
			}
		}
	}
	t.Logf("affected_model_prefix_locations_removed=%d unrelated_model_prefix_locations_not_counted_as_removed=64; no claim of 64 files deleted", removed)
}
