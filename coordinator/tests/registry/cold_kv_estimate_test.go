package registry_test

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/kvbudget"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const coldKVModel = "test/gemma-cold-artifact"

func coldKVModelInfo(id, digest string) protocol.ModelInfo {
	return protocol.ModelInfo{ID: id, WeightHash: strings.Repeat(digest, 64), SizeBytes: 28_000_000_000, ModelType: "gemma4", Quantization: "4bit"}
}

func coldKVProvider(t testing.TB, r *production.Registry, id string, memory int, models ...protocol.ModelInfo) *production.Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = models
	msg.Version = "0.9.19"
	msg.TemplateHashes = map[string]string{"mlx_metallib": strings.Repeat("b", 64)}
	msg.Hardware.MemoryGB = memory
	p := r.Register(id, nil, msg)
	p.SetVersion(msg.Version)
	p.Mu().Lock()
	p.TrustLevel = production.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.MetallibVerified = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.Mu().Unlock()
	setSchedulerProviderSerial(p, id)
	return p
}

func coldKVSlot(model protocol.ModelInfo, rate int64) protocol.BackendSlotCapacity {
	backend := "contiguous"
	return protocol.BackendSlotCapacity{
		Model: model.ID, State: "idle", KVBytesPerToken: rate, ActiveTokenBudgetMax: 100_000,
		KVBackend: &backend,
		PromptWorkIdentity: &protocol.PromptWorkIdentity{
			ModelArtifactHash: model.WeightHash, PromptContractID: strings.Repeat("c", 64),
		},
	}
}

func coldKVHeartbeat(t testing.TB, r *production.Registry, p *production.Provider, seq uint64, slots ...protocol.BackendSlotCapacity) bool {
	t.Helper()
	free := 32.0
	return r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", SystemMetrics: protocol.SystemMetrics{ThermalState: "nominal"},
		BackendCapacity: &protocol.BackendCapacity{
			CapacitySeq: seq, TotalMemoryGB: float64(p.Hardware.MemoryGB), FreeForLoadGB: &free, Slots: slots,
			Telemetry: &protocol.CapacityTelemetry{ProcessMemory: &protocol.ProcessMemoryTelemetry{Generation: 1, SampleSeq: seq}},
		},
	})
}

func TestColdKVEstimateUsesLiveArtifactRateForFirstLoad(t *testing.T) {
	r := production.New(testLogger())
	model := coldKVModelInfo(coldKVModel, "a")
	r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
	source := coldKVProvider(t, r, "source", 64, model)
	cold := coldKVProvider(t, r, "cold", 48, model)
	coldKVHeartbeat(t, r, source, 1, coldKVSlot(model, 20_480))
	coldKVHeartbeat(t, r, cold, 1)
	if live := r.PredictServable(model.ID, 30_000, 30_000, 256, 0, production.RequestTraits{}, false, source.ID); live.ProviderCount != 1 {
		t.Fatalf("source must be live: %+v", live)
	}

	verdict := r.PredictServable(model.ID, 30_000, 30_000, 256, 0, production.RequestTraits{}, false, cold.ID)
	want := memorypolicy.ColdTokenBudgetWithOffload(48, 28, 0, 20_480, model.ID)
	if !verdict.Servable || verdict.ProviderCount != 1 || verdict.FleetMaxBudget != want {
		t.Fatalf("first-load forecast = %+v, want one cold provider with budget %d", verdict, want)
	}
	pr := &production.PendingRequest{RequestID: "cold-request", Model: model.ID, EstimatedPromptTokens: 30_000, RequestedMaxTokens: 256, AllowedProviderSerials: []string{cold.ID}}
	selected, decision := r.ReserveProviderEx(model.ID, pr)
	if selected != cold {
		t.Fatalf("first-load candidate = %v, decision %+v; want cold provider", selected, decision)
	}
	cold.RemovePending(pr.RequestID)
}

func TestColdKVEstimateKeepsUnknownModelFallback(t *testing.T) {
	r := production.New(testLogger())
	known := coldKVModelInfo(coldKVModel, "a")
	unknown := coldKVModelInfo("test/other-cold-artifact", "d")
	r.SetModelCatalog([]production.CatalogEntry{
		{ID: known.ID, WeightHash: known.WeightHash, SizeGB: 28, MinRAMGB: 48},
		{ID: unknown.ID, WeightHash: unknown.WeightHash, SizeGB: 28, MinRAMGB: 48},
	})
	source := coldKVProvider(t, r, "source", 64, known)
	cold := coldKVProvider(t, r, "cold", 48, known, unknown)
	coldKVHeartbeat(t, r, source, 1, coldKVSlot(known, 20_480))
	coldKVHeartbeat(t, r, cold, 1)
	verdict := r.PredictServable(unknown.ID, 30_000, 30_000, 256, 0, production.RequestTraits{}, false, cold.ID)
	want := memorypolicy.ColdTokenBudgetWithOffload(48, 28, 0, 0, unknown.ID)
	if verdict.Servable || verdict.FleetMaxBudget != want {
		t.Fatalf("unobserved model forecast = %+v, want bounded fallback %d", verdict, want)
	}
}

func assertColdKVForecast(t *testing.T, r *production.Registry, target *production.Provider, model string, rate int64) {
	t.Helper()
	verdict := r.PredictServable(model, 30_000, 30_000, 256, 0, production.RequestTraits{}, false, target.ID)
	want := memorypolicy.ColdTokenBudgetWithOffload(float64(target.Hardware.MemoryGB), 28, 0, rate, model)
	if verdict.ProviderCount != 1 || verdict.FleetMaxBudget != want || verdict.Servable != (want >= 30_256) {
		t.Fatalf("forecast = %+v, want one target with %d-token budget at %d bytes/token", verdict, want, rate)
	}
}

func TestColdKVEstimateUsesMaximumNativeRateAcrossBackends(t *testing.T) {
	r := production.New(testLogger())
	model := coldKVModelInfo(coldKVModel, "a")
	r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
	low := coldKVProvider(t, r, "contiguous", 64, model)
	high := coldKVProvider(t, r, "paged", 64, model)
	cold := coldKVProvider(t, r, "cold", 48, model)
	coldKVHeartbeat(t, r, cold, 1)
	coldKVHeartbeat(t, r, low, 1, coldKVSlot(model, 20_480))
	for i, rate := range []int64{40_960, 600_000} {
		slot := coldKVSlot(model, rate)
		backend := "paged"
		slot.KVBackend = &backend
		// Native precision and assistant allocation choices need not match the
		// cheaper peer. Forecast the largest observation, not an arbitrary peer.
		coldKVHeartbeat(t, r, high, uint64(i+1), slot)
		assertColdKVForecast(t, r, cold, model.ID, rate)
	}
	r.Disconnect(high.ID)
	assertColdKVForecast(t, r, cold, model.ID, 20_480)
}

func TestColdKVEstimateRejectsInvalidOrWithdrawnEvidence(t *testing.T) {
	tests := []struct {
		name   string
		change func(*testing.T, *production.Registry, *production.Provider, *production.Provider, protocol.ModelInfo)
	}{
		{"disconnected", func(_ *testing.T, r *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			r.Disconnect(source.ID)
		}},
		{"untrusted", func(_ *testing.T, r *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			r.MarkUntrusted(source.ID)
		}},
		{"runtime_unverified", func(_ *testing.T, _ *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			source.Mu().Lock()
			defer source.Mu().Unlock()
			source.RuntimeVerified = false
		}},
		{"metallib_unverified", func(_ *testing.T, _ *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			source.Mu().Lock()
			defer source.Mu().Unlock()
			source.MetallibVerified = false
		}},
		{"private_source", func(_ *testing.T, _ *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			source.Mu().Lock()
			defer source.Mu().Unlock()
			source.PrivateOnly = true
		}},
		{"stale_challenge", func(_ *testing.T, _ *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			source.Mu().Lock()
			defer source.Mu().Unlock()
			source.LastChallengeVerified = time.Now().Add(-time.Hour)
		}},
		{"different_runtime", func(_ *testing.T, _ *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			source.SetVersion("0.9.18")
		}},
		{"different_metallib", func(_ *testing.T, _ *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			source.Mu().Lock()
			defer source.Mu().Unlock()
			source.TemplateHashes["mlx_metallib"] = strings.Repeat("e", 64)
		}},
		{"unknown_target_artifact", func(_ *testing.T, r *production.Registry, _, cold *production.Provider, model protocol.ModelInfo) {
			r.UpdateModelWeightHashes(cold.ID, map[string]string{model.ID: ""})
		}},
		{"unknown_target_runtime", func(_ *testing.T, _ *production.Registry, _, cold *production.Provider, _ protocol.ModelInfo) {
			cold.SetVersion("")
		}},
		{"different_artifact", func(t *testing.T, r *production.Registry, source, _ *production.Provider, model protocol.ModelInfo) {
			revised := model
			revised.WeightHash = strings.Repeat("d", 64)
			r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: revised.WeightHash, ServingWeightHashes: []string{model.WeightHash}, SizeGB: 28, MinRAMGB: 48}})
			merged, _ := r.MergeProviderModels(source.ID, []protocol.ModelInfo{revised})
			if len(merged) != 1 {
				t.Fatal("revised source artifact was not accepted")
			}
			coldKVHeartbeat(t, r, source, 2, coldKVSlot(revised, 20_480))
		}},
		{"old_slot_after_artifact_change", func(t *testing.T, r *production.Registry, source, cold *production.Provider, model protocol.ModelInfo) {
			revised := model
			revised.WeightHash = strings.Repeat("d", 64)
			r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: revised.WeightHash, ServingWeightHashes: []string{model.WeightHash}, SizeGB: 28, MinRAMGB: 48}})
			for _, p := range []*production.Provider{source, cold} {
				if merged, _ := r.MergeProviderModels(p.ID, []protocol.ModelInfo{revised}); len(merged) != 1 {
					t.Fatal("revised inventory was not accepted")
				}
			}
			// The old slot still names the old loaded artifact. Re-registering
			// both inventories must not relabel its KV rate as the new artifact.
		}},
		{"model_removed", func(t *testing.T, r *production.Registry, source, _ *production.Provider, model protocol.ModelInfo) {
			replacement := coldKVModelInfo("test/replacement", "d")
			r.SetModelCatalog([]production.CatalogEntry{
				{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48},
				{ID: replacement.ID, WeightHash: replacement.WeightHash, SizeGB: 28, MinRAMGB: 48},
			})
			r.SetModelAliases(map[string]production.AliasTarget{"alias": {Desired: replacement.ID, Previous: model.ID}})
			_, dropped := r.MergeProviderModels(source.ID, []protocol.ModelInfo{replacement})
			if len(dropped) != 1 || dropped[0] != model.ID {
				t.Fatalf("model was not removed: %v", dropped)
			}
		}},
		{"nil_capacity", func(_ *testing.T, r *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			r.Heartbeat(source.ID, &protocol.HeartbeatMessage{Status: "idle"})
		}},
		{"absent_slot", func(t *testing.T, r *production.Registry, source, _ *production.Provider, _ protocol.ModelInfo) {
			coldKVHeartbeat(t, r, source, 2)
		}},
	}
	for _, state := range []string{"crashed", "reloading", "idle_shutdown"} {
		tests = append(tests, struct {
			name   string
			change func(*testing.T, *production.Registry, *production.Provider, *production.Provider, protocol.ModelInfo)
		}{state, func(t *testing.T, r *production.Registry, source, _ *production.Provider, model protocol.ModelInfo) {
			slot := coldKVSlot(model, 20_480)
			slot.State = state
			coldKVHeartbeat(t, r, source, 2, slot)
		}})
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := production.New(testLogger())
			model := coldKVModelInfo(coldKVModel, "a")
			r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
			source := coldKVProvider(t, r, "source", 64, model)
			cold := coldKVProvider(t, r, "cold", 48, model)
			coldKVHeartbeat(t, r, source, 1, coldKVSlot(model, 20_480))
			coldKVHeartbeat(t, r, cold, 1)
			assertColdKVForecast(t, r, cold, model.ID, 20_480)
			tc.change(t, r, source, cold, model)
			assertColdKVForecast(t, r, cold, model.ID, 0)
		})
	}
}

func TestColdKVEstimateRejectsMalformedNativeSamples(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*protocol.BackendSlotCapacity)
	}{
		{"zero_rate", func(slot *protocol.BackendSlotCapacity) { slot.KVBytesPerToken = 0 }},
		{"negative_rate", func(slot *protocol.BackendSlotCapacity) { slot.KVBytesPerToken = -1 }},
		{"oversized_rate", func(slot *protocol.BackendSlotCapacity) { slot.KVBytesPerToken = kvbudget.MaxBytesPerToken + 1 }},
		{"overflow_rate", func(slot *protocol.BackendSlotCapacity) { slot.KVBytesPerToken = math.MaxInt64 }},
		{"unknown_backend", func(slot *protocol.BackendSlotCapacity) { slot.KVBackend = nil }},
		{"wedged", func(slot *protocol.BackendSlotCapacity) { slot.WedgeSuspected = true }},
		{"missing_loaded_identity", func(slot *protocol.BackendSlotCapacity) { slot.PromptWorkIdentity = nil }},
		{"wrong_loaded_identity", func(slot *protocol.BackendSlotCapacity) {
			slot.PromptWorkIdentity.ModelArtifactHash = strings.Repeat("d", 64)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := production.New(testLogger())
			model := coldKVModelInfo(coldKVModel, "a")
			r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
			source := coldKVProvider(t, r, "source", 64, model)
			cold := coldKVProvider(t, r, "cold", 48, model)
			slot := coldKVSlot(model, 20_480)
			tc.change(&slot)
			coldKVHeartbeat(t, r, source, 1, slot)
			coldKVHeartbeat(t, r, cold, 1)
			assertColdKVForecast(t, r, cold, model.ID, 0)
		})
	}
}

func TestColdKVEstimateUsesAcceptedCapacityFreshness(t *testing.T) {
	now := time.Now()
	r := production.NewWithDependencies(testLogger(), production.Dependencies{HeartbeatNow: func() time.Time { return now }})
	model := coldKVModelInfo(coldKVModel, "a")
	r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
	source := coldKVProvider(t, r, "source", 64, model)
	cold := coldKVProvider(t, r, "cold", 48, model)
	coldKVHeartbeat(t, r, source, 2, coldKVSlot(model, 40_960))
	coldKVHeartbeat(t, r, cold, 1)
	if coldKVHeartbeat(t, r, source, 1, coldKVSlot(model, 20_480)) {
		t.Fatal("stale lower-rate snapshot was accepted")
	}
	assertColdKVForecast(t, r, cold, model.ID, 40_960)

	now = time.Now().Add(-production.DefaultProviderHeartbeatTimeout - time.Second)
	coldKVHeartbeat(t, r, source, 3, coldKVSlot(model, 20_480))
	acceptedAt := source.CapacityAcceptedAt
	if coldKVHeartbeat(t, r, source, 2, coldKVSlot(model, 20_480)) {
		t.Fatal("stale sequence refreshed rate evidence")
	}
	if source.CapacityAcceptedAt != acceptedAt || !source.LastHeartbeat.After(acceptedAt) {
		t.Fatal("fixture did not separate accepted capacity age from liveness")
	}
	assertColdKVForecast(t, r, cold, model.ID, 0)
	now = time.Now()
	coldKVHeartbeat(t, r, source, 4, coldKVSlot(model, 20_480))
	assertColdKVForecast(t, r, cold, model.ID, 20_480)
}
