package registry_test

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/modelindex"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type fleetSampleCandidates struct {
	index modelindex.Index[*production.Provider]
	mu    sync.Mutex
	calls map[string]int
}

func (c *fleetSampleCandidates) AppendProviders(model string, dst []*production.Provider) []*production.Provider {
	c.mu.Lock()
	if c.calls == nil {
		c.calls = make(map[string]int)
	}
	c.calls[model]++
	c.mu.Unlock()
	return c.index.AppendProviders(model, dst)
}

func (c *fleetSampleCandidates) takeCalls() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	calls := c.calls
	c.calls = nil
	return calls
}

func TestFleetSampleColdKVForecastVisitsNeededModelsOnce(t *testing.T) {
	for _, pending := range []bool{false, true} {
		t.Run(fmt.Sprintf("pending=%t", pending), func(t *testing.T) {
			candidates := &fleetSampleCandidates{}
			r := production.NewWithDependencies(testLogger(), production.Dependencies{
				ModelAdvertisements: &candidates.index, ModelCandidates: candidates,
			})
			resident := coldKVModelInfo("test/sampled-resident", "d")
			cold := coldKVModelInfo(coldKVModel, "a")
			r.SetModelCatalog([]production.CatalogEntry{
				{ID: resident.ID, WeightHash: resident.WeightHash, SizeGB: 1, MinRAMGB: 8},
				{ID: cold.ID, WeightHash: cold.WeightHash, SizeGB: 28, MinRAMGB: 48},
			})
			const targetCount = 8
			for i := 0; i < targetCount; i++ {
				p := coldKVProvider(t, r, fmt.Sprintf("target-%d", i), 64, resident, cold)
				coldKVHeartbeat(t, r, p, 1, coldKVSlot(resident, 10_000))
				if pending {
					p.AddPending(&production.PendingRequest{RequestID: fmt.Sprintf("pending-%d", i), Model: cold.ID, RequestedMaxTokens: 20_000})
				}
			}
			source := coldKVProvider(t, r, "source", 64, resident, cold)
			coldKVHeartbeat(t, r, source, 1, coldKVSlot(cold, 20_480))
			candidates.takeCalls()

			rows := r.FleetSample(time.Now())
			calls := candidates.takeCalls()
			wantCold := 0
			if pending {
				wantCold = 1
			}
			if calls[resident.ID] != 0 || calls[cold.ID] != wantCold {
				t.Fatalf("model-index visits=%v, want no idle-advertisement scan and %d cold-pending scan", calls, wantCold)
			}
			if len(rows) != targetCount+1 {
				t.Fatalf("sample rows=%d, want %d", len(rows), targetCount+1)
			}
			for _, row := range rows {
				if row.EligibilityReason != production.EligibilityReasonEligible {
					t.Fatalf("native-priced pending work should fit: provider=%s reason=%s", row.ProviderID, row.EligibilityReason)
				}
			}
			if !pending {
				return
			}

			// Each later sample refreshes its operation-local observations. A
			// withdrawn donor must not leave cheap pending charges behind.
			r.Disconnect(source.ID)
			candidates.takeCalls()
			rows = r.FleetSample(time.Now())
			if len(rows) != targetCount {
				t.Fatalf("disconnected donor retained a row: %d", len(rows))
			}
			if calls := candidates.takeCalls(); calls[cold.ID] != 1 || calls[resident.ID] != 0 {
				t.Fatalf("post-disconnect model-index visits=%v, want one cold lookup", calls)
			}
			for _, row := range rows {
				if row.EligibilityReason != production.GateFreeMemory.String() {
					t.Fatalf("unknown pending rate must retain conservative pool charge: provider=%s reason=%s", row.ProviderID, row.EligibilityReason)
				}
				count, rejected, _ := r.QuickCapacityCheck(resident.ID, 500, 256, production.RequestTraits{}, row.ProviderID)
				if count != 0 || rejected != 1 {
					t.Fatalf("sampler differs from routing probe: count=%d rejected=%d", count, rejected)
				}
			}
		})
	}
}

func TestFleetSampleColdSlotUsesNativeForecast(t *testing.T) {
	r := production.New(testLogger())
	model := coldKVModelInfo(coldKVModel, "a")
	r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
	source := coldKVProvider(t, r, "source", 64, model)
	loaded := coldKVSlot(model, 16_000_000)
	loaded.ActiveTokenBudgetMax = 1000
	coldKVHeartbeat(t, r, source, 1, loaded)
	target := coldKVProvider(t, r, "target", 48, model)
	unloaded := coldKVSlot(model, 0)
	unloaded.State, unloaded.ActiveTokenBudgetMax = "idle_shutdown", 0
	coldKVHeartbeat(t, r, target, 1, unloaded)
	row := rowFor(t, r.FleetSample(time.Now()), target.ID, model.ID)
	if row.EligibilityReason != production.GateFreeMemory.String() {
		t.Fatalf("cold slot bypassed its native forecast: %s", row.EligibilityReason)
	}
	count, rejected, _ := r.QuickCapacityCheck(model.ID, 500, 256, production.RequestTraits{}, target.ID)
	if count != 0 || rejected != 1 {
		t.Fatalf("sampler differs from routing probe: count=%d rejected=%d", count, rejected)
	}
}
