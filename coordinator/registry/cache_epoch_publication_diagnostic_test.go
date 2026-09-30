package registry

import (
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Component witness, not a production workload or full SSD rehydration test.
// One model's epoch transition withdraws all its advertised prefix locations,
// including unrelated prefixes, while preserving another model's locations.
func TestDiagnosticCacheEpochFanout(t *testing.T) {
	r := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	a := testV2Capability("11111111-1111-1111-1111-111111111111")
	b := a
	b.ModelID = "other-model"
	p := &Provider{ID: "fixture-provider", PrefixCacheProtocol: 2,
		Models:              []protocol.ModelInfo{{ID: a.ModelID, WeightHash: a.ModelAggregateHash}, {ID: b.ModelID, WeightHash: b.ModelAggregateHash}},
		PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{a.ModelID: a, b.ModelID: b}}
	insertTestProvider(r, p)
	r.cacheRouting.mu.Lock()
	for _, cap := range []protocol.PrefixCacheV2Capability{a, b} {
		for i := 0; i < 64; i++ {
			r.cacheRouting.upsertHolderLocked(fmt.Sprintf("%s-prefix-%d", cap.ModelID, i), cacheHolder{
				ProviderID: p.ID, ModelID: cap.ModelID, CacheEpoch: cap.CacheEpoch,
				UpdatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Minute)})
		}
	}
	r.cacheRouting.mu.Unlock()
	a.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	r.cacheRouting.mu.Lock()
	defer r.cacheRouting.mu.Unlock()
	removed := r.cacheRouting.holderRemoved[string(cacheHolderRemovalEpochChange)]
	if removed != 64 {
		t.Fatalf("epoch removed %d locations, want exactly the affected model's 64", removed)
	}
	if r.cacheRouting.holderCount != 64 {
		t.Fatalf("retained holders=%d, want other model's 64", r.cacheRouting.holderCount)
	}
	for key, holders := range r.cacheRouting.holders {
		for _, holder := range holders {
			if holder.ModelID != b.ModelID {
				t.Fatalf("unexpected surviving holder at %s", key)
			}
		}
	}
	t.Logf("affected_model_prefix_locations_removed=%d unrelated_model_prefix_locations_not_counted_as_removed=64; no claim of 64 files deleted", removed)
}
