package registry_test

import (
	"fmt"
	"sync"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestColdKVEstimatePreservesOwnSlotAuthority(t *testing.T) {
	r := production.New(testLogger())
	model := coldKVModelInfo(coldKVModel, "a")
	r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
	source := coldKVProvider(t, r, "source", 64, model)
	local := coldKVProvider(t, r, "local", 48, model)
	coldKVHeartbeat(t, r, source, 1, coldKVSlot(model, 600_000))
	for i, tc := range []struct {
		name      string
		rate, max int64
		want      bool
	}{
		{"positive_own_rate", 20_480, 80_000, true},
		{"positive_own_rate_zero_max", 20_480, 0, false},
		{"legacy_omitted_rate_and_max", 0, 0, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			slot := coldKVSlot(model, tc.rate)
			slot.ActiveTokenBudgetMax = tc.max
			coldKVHeartbeat(t, r, local, uint64(i+1), slot)
			pr := &production.PendingRequest{RequestID: tc.name, Model: model.ID, RequestedMaxTokens: 30_000, AllowedProviderSerials: []string{local.ID}}
			selected, decision := r.ReserveProviderEx(model.ID, pr)
			if (selected == local) != tc.want {
				t.Fatalf("own slot admit = %v, want %v; %+v", selected != nil, tc.want, decision)
			}
			if selected != nil {
				selected.RemovePending(pr.RequestID)
			}
		})
	}
}

func TestColdKVEstimatePricesWholeProviderPendingBytes(t *testing.T) {
	r := production.New(testLogger())
	coldModel := coldKVModelInfo(coldKVModel, "a")
	resident := coldKVModelInfo("test/resident-small-kv", "d")
	r.SetModelCatalog([]production.CatalogEntry{
		{ID: coldModel.ID, WeightHash: coldModel.WeightHash, SizeGB: 28, MinRAMGB: 48},
		{ID: resident.ID, WeightHash: resident.WeightHash, SizeGB: 1, MinRAMGB: 8},
	})
	source := coldKVProvider(t, r, "source", 64, coldModel)
	target := coldKVProvider(t, r, "target", 64, coldModel, resident)
	coldKVHeartbeat(t, r, source, 1, coldKVSlot(coldModel, 20_480))
	// One physical 1GB grant. Learning a cold rate must not create another grant.
	coldKVHeartbeat(t, r, target, 1, coldKVSlot(resident, 10_000))
	pr := &production.PendingRequest{RequestID: "first-cold", Model: coldModel.ID, RequestedMaxTokens: 20_000, AllowedProviderSerials: []string{target.ID}}
	if selected, decision := r.ReserveProviderEx(coldModel.ID, pr); selected != target {
		t.Fatalf("cold request must fit the byte pool: %+v", decision)
	}
	defer target.RemovePending(pr.RequestID)

	const remaining = (100_000*10_000 - 20_000*20_480) / 10_000
	found := false
	for _, capacity := range r.ModelCapacitySnapshot() {
		if capacity.ModelID == resident.ID {
			found = true
			if capacity.TokenBudgetTotal != 100_000 || capacity.TokenBudgetRemaining != remaining {
				t.Fatalf("pending cold bytes changed grants or used another rate: %+v, want remaining %d", capacity, remaining)
			}
		}
	}
	if !found {
		t.Fatal("resident capacity missing")
	}
	// This incoming model's index contains only target; its cold pending model
	// must still use the source from a DIFFERENT model index, not 400k/token.
	for _, delta := range []int{1, 0} {
		incoming := &production.PendingRequest{RequestID: fmt.Sprintf("resident-%d", delta), Model: resident.ID, RequestedMaxTokens: remaining + delta}
		selected, decision := r.ReserveProviderEx(resident.ID, incoming)
		if (selected == target) != (delta == 0) {
			t.Fatalf("resident boundary +%d selected=%v: %+v", delta, selected != nil, decision)
		}
		if selected != nil {
			selected.RemovePending(incoming.RequestID)
		}
	}
	r.Disconnect(source.ID)
	// The same pending request becomes conservatively charged at 400k when no
	// current observation survives. Expiry/removal never turns bytes unknown.
	for _, capacity := range r.ModelCapacitySnapshot() {
		if capacity.ModelID == resident.ID && (capacity.TokenBudgetRemaining != 0 || capacity.Ready) {
			t.Fatalf("removed source left optimistic pending credit: %+v", capacity)
		}
	}
}

func TestColdKVEstimateConcurrentHeartbeatInventoryAndDisconnect(t *testing.T) {
	r := production.New(testLogger())
	model := coldKVModelInfo(coldKVModel, "a")
	r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
	source := coldKVProvider(t, r, "source", 64, model)
	target := coldKVProvider(t, r, "target", 48, model)
	coldKVHeartbeat(t, r, source, 1, coldKVSlot(model, 20_480))
	coldKVHeartbeat(t, r, target, 1)
	var workers sync.WaitGroup
	workers.Add(3)
	go func() {
		defer workers.Done()
		for i := 2; i < 50; i++ {
			coldKVHeartbeat(t, r, source, uint64(i), coldKVSlot(model, 20_480))
		}
	}()
	go func() {
		defer workers.Done()
		for i := 0; i < 50; i++ {
			hash := model.WeightHash
			if i%2 == 0 {
				hash = ""
			}
			r.UpdateModelWeightHashes(source.ID, map[string]string{model.ID: hash})
		}
		r.Disconnect(source.ID)
	}()
	go func() {
		defer workers.Done()
		for i := 0; i < 50; i++ {
			pr := &production.PendingRequest{RequestID: fmt.Sprintf("concurrent-%d", i), Model: model.ID, RequestedMaxTokens: 30_000, AllowedProviderSerials: []string{target.ID}}
			if selected, _ := r.ReserveProviderEx(model.ID, pr); selected != nil {
				selected.RemovePending(pr.RequestID)
			}
			r.ModelCapacitySnapshot()
		}
	}()
	workers.Wait()
	assertColdKVForecast(t, r, target, model.ID, 0)
}

func TestColdKVEstimateReachesAutopilotColdFit(t *testing.T) {
	r, control, _ := newAutopilotControllerTest(t, true)
	model := coldKVModelInfo(coldKVModel, "a")
	r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
	source := coldKVProvider(t, r.Registry, "source", 64, model)
	target := coldKVProvider(t, r.Registry, "target", 48, model)
	for _, p := range []*production.Provider{source, target} {
		p.Mu().Lock()
		p.PrefillTPS, p.DecodeTPS = 2000, 100
		p.Mu().Unlock()
	}
	coldKVHeartbeat(t, r.Registry, source, 1, coldKVSlot(model, 20_480))
	coldKVHeartbeat(t, r.Registry, target, 1)
	now := time.Now()
	sample := autopilot.DemandSample{Model: model.ID, ReceivedAt: now, PromptTokens: 30_000, RequestedMaxTokens: 256, DeadlineKnown: true}
	r.demand.Record(sample, now, r.cfg.DemandWindow)
	key := autopilot.ShapeKey(sample)
	for _, want := range []bool{true, false} {
		found := false
		fleet := control.Fleet(time.Now())
		for _, node := range fleet.Nodes {
			if node.ID == target.ID {
				found = true
				fit := node.Fits[key]
				if fit.Rate <= 0 || fit.MeetsDeadline != want {
					t.Fatalf("cold fit %+v, want positive rate with admitted envelope=%v; key=%q node=%+v exclusions=%v demand=%+v", fit, want, key, node, fleet.Excluded, fleet.Demand)
				}
			}
		}
		if !found {
			t.Fatal("cold target missing from Autopilot snapshot")
		}
		r.Disconnect(source.ID)
	}
}
