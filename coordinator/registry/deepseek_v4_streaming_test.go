package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Coverage for the FLEET path of DeepSeek-V4 (and any future) MoE
// expert-SSD-streaming model: coordinator memory gates were written assuming
// catalog SizeGB approximates the resident weight footprint. For a streaming
// model the on-disk manifest total (141GB for DeepSeek-V4-Flash-4bit) is NOT
// that footprint — the provider streams ~125GB of routed-expert tensors
// straight from disk and never loads them resident (see
// provider-swift/Sources/ProviderCoreFoundation/ExpertStreamingAdmission.swift).
//
// The registration fix (api.catalogSizeGBForRow / the "catalog_size_gb"
// RuntimeParameters override) feeds the coordinator a SizeGB that represents
// the true load-weight (~16GB, the non-`switch_mlp` on-disk tensor total) and
// a MinRAMGB floor (36, the smallest documented viable box) that governs
// structural fit independent of SizeGB. These tests exercise the coordinator
// registry gates directly with that combination — SizeGB: dsv4StreamingSizeGB,
// MinRAMGB: dsv4StreamingMinRAMGB — across the fleet's documented box tiers
// (36/48/64/96/128GB, docs/reference/deepseek-v4-serving.md).
const (
	dsv4StreamingSizeGB   = 16.0 // non-switch_mlp on-disk tensor total (raw, unpadded)
	dsv4StreamingMinRAMGB = 36   // smallest documented viable box (ExpertStreamingAdmissionTests)
)

// dsv4CatalogEntry returns the recommended catalog registration for a
// DeepSeek-V4-Flash-4bit-shaped streaming model.
func dsv4CatalogEntry(model string) CatalogEntry {
	return CatalogEntry{ID: model, SizeGB: dsv4StreamingSizeGB, MinRAMGB: dsv4StreamingMinRAMGB}
}

// dsv4RealisticFreeForLoadGB approximates what a real Swift provider would
// report for ModelLoadAdmission.maxLoadableWeightGb on an otherwise-idle box:
// 90% unified-memory cap minus a small OS/operator reserve. Mirrors the
// UnifiedMemoryCap invariant documented in ExpertStreamingAdmission.swift
// without depending on provider-swift (this package is Go-only).
func dsv4RealisticFreeForLoadGB(totalMemGB float64) float64 {
	free := 0.9*totalMemGB - 4.0
	if free < 0 {
		return 0
	}
	return free
}

// makeDSV4ColdProvider registers a provider that advertises the streaming
// model but has it NOT loaded (cold, "idle_shutdown"), with a realistic
// FreeForLoadGB for its memory tier. Mirrors makeSchedulerProvider /
// makeWarmPoolColdProvider's conventions.
func makeDSV4ColdProvider(t *testing.T, reg *Registry, id, model string, totalMemGB float64) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Hardware.MemoryGB = int(totalMemGB)
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "deepseek_v4", Quantization: "4bit", SizeBytes: 141_000_000_000}}
	p := reg.Register(id, nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	freeForLoad := dsv4RealisticFreeForLoadGB(totalMemGB)
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: totalMemGB,
		FreeForLoadGB: &freeForLoad,
		Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "idle_shutdown"}},
	}
	p.mu.Unlock()
	return p
}

// makeDSV4WarmProvider registers a provider with the streaming model already
// resident ("idle", loaded, no in-flight requests), reporting a per-slot
// MaxConcurrency of 1 — mirroring BatchScheduler.effectiveMaxConcurrentRequests
// for a requiresSequentialServing model (provider-swift
// BatchScheduler+Telemetry.swift) — and an ActiveTokenBudgetMax representative
// of the real post-load KV headroom on that box.
func makeDSV4WarmProvider(t *testing.T, reg *Registry, id, model string, totalMemGB float64, activeTokenBudgetMax int64) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Hardware.MemoryGB = int(totalMemGB)
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "deepseek_v4", Quantization: "4bit", SizeBytes: 141_000_000_000}}
	p := reg.Register(id, nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: totalMemGB,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                model,
			State:                "idle",
			MaxConcurrency:       1,
			ActiveTokenBudgetMax: activeTokenBudgetMax,
		}},
	}
	p.mu.Unlock()
	return p
}

// TestDSV4StreamingCatalogAdmitsColdLoadAcrossFleetSizes is the core fleet-gate
// regression: with the streaming-aware catalog registration (SizeGB=16,
// MinRAMGB=36), a cold (not-yet-loaded) provider on every documented box tier
// must be admitted for both the structural fit gate (modelFitsHardware) and the
// free-memory/free-for-load gate (freeMemoryAdmits -> reportedFreeForLoadAdmits).
// Before the fix (SizeGB derived from the 141GB on-disk manifest total).
func TestDSV4StreamingCatalogAdmitsColdLoadAcrossFleetSizes(t *testing.T) {
	model := "deepseek-v4-flash-4bit"
	for _, totalMemGB := range []float64{36, 48, 64, 96, 128} {
		t.Run(fmtGB(totalMemGB), func(t *testing.T) {
			reg := New(testLogger())
			reg.SetModelCatalog([]CatalogEntry{dsv4CatalogEntry(model)})
			makeDSV4ColdProvider(t, reg, "p", model, totalMemGB)

			candidates, capacityRejections, tooLarge := reg.QuickCapacityCheck(model, 500, 256, RequestTraits{})
			if tooLarge != 0 {
				t.Fatalf("%.0fGB box: modelTooLarge=%d, want 0 (min_ram_gb=%d must admit)", totalMemGB, tooLarge, dsv4StreamingMinRAMGB)
			}
			if candidates != 1 || capacityRejections != 0 {
				t.Fatalf("%.0fGB box: candidates=%d capacityRejections=%d, want 1/0 (streaming-aware size_gb=%.0f must fit free-for-load)",
					totalMemGB, candidates, capacityRejections, dsv4StreamingSizeGB)
			}

			p := reg.GetProvider("p")
			selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
				RequestID: "dsv4-cold-" + fmtGB(totalMemGB), Model: model, RequestedMaxTokens: 256,
			})
			if selected == nil || selected.ID != p.ID {
				t.Fatalf("%.0fGB box: ReserveProviderEx selected=%v decision=%+v, want provider %q", totalMemGB, selected, decision, p.ID)
			}
		})
	}
}

// TestDSV4StreamingCatalogRejectsBelowMinRAM proves the structural floor still
// bites: a box under the documented minimum (36GB) must be excluded as
// model_too_large (permanent), never treated as merely transient capacity
// pressure, regardless of the small streaming-aware SizeGB.
func TestDSV4StreamingCatalogRejectsBelowMinRAM(t *testing.T) {
	reg := New(testLogger())
	model := "deepseek-v4-flash-4bit"
	reg.SetModelCatalog([]CatalogEntry{dsv4CatalogEntry(model)})
	makeDSV4ColdProvider(t, reg, "tiny", model, 24)

	candidates, capacityRejections, tooLarge := reg.QuickCapacityCheck(model, 500, 256, RequestTraits{})
	if tooLarge != 1 || candidates != 0 || capacityRejections != 0 {
		t.Fatalf("24GB box: (cand=%d, capRej=%d, tooLarge=%d), want (0,0,1)", candidates, capacityRejections, tooLarge)
	}
}

// TestDSV4StreamingRawDiskSizeRejectsEveryBoxIncludingTheLargest is the
// regression the fix addresses: registering the catalog with the NAIVE
// on-disk manifest total (141GB, what TotalSizeBytes/1e9 produces without the
// override) makes reportedFreeForLoadAdmits reject a cold load on EVERY
// fleet box, including the largest (128GB) — because 141GB * the padding
// factor exceeds any realistic free-for-load headroom. This pins the "before"
// behavior so a future change can't silently reintroduce it un-noticed.
func TestDSV4StreamingRawDiskSizeRejectsEveryBoxIncludingTheLargest(t *testing.T) {
	reg := New(testLogger())
	model := "deepseek-v4-flash-4bit"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 141.0, MinRAMGB: dsv4StreamingMinRAMGB}})
	makeDSV4ColdProvider(t, reg, "biggest", model, 128)

	candidates, capacityRejections, tooLarge := reg.QuickCapacityCheck(model, 500, 256, RequestTraits{})
	if tooLarge != 0 {
		t.Fatalf("128GB box: modelTooLarge=%d, want 0 (min_ram_gb gate must still pass)", tooLarge)
	}
	if candidates != 0 || capacityRejections != 1 {
		t.Fatalf("128GB box with raw on-disk size_gb=141: (cand=%d, capRej=%d), want (0,1) — "+
			"this must fail today's naive registration to prove the streaming-aware override is necessary", candidates, capacityRejections)
	}
}

// TestDSV4StreamingColdLoadSpillEligible exercises ColdSpillProviders — the
// exact predicate TriggerModelSwaps/bestModelLoadProviderLocked uses to decide
// whether a cold, idle, fitting provider is a valid load_model target. A
// provider with no in-flight work, the streaming-aware catalog entry, and a
// realistic FreeForLoadGB must count as a cold-spill target on a mid-tier box.
func TestDSV4StreamingColdLoadSpillEligible(t *testing.T) {
	reg := New(testLogger())
	model := "deepseek-v4-flash-4bit"
	reg.SetModelCatalog([]CatalogEntry{dsv4CatalogEntry(model)})
	makeDSV4ColdProvider(t, reg, "cold64", model, 64)

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false); n != 1 {
		t.Fatalf("ColdSpillProviders = %d, want 1 (streaming-aware size must clear the cold-load gate)", n)
	}
}

// TestDSV4StreamingColdLoadSpillRejectedWithRawDiskSize is the ColdSpillProviders
// mirror of TestDSV4StreamingRawDiskSizeRejectsEveryBoxIncludingTheLargest: the
// naive on-disk size must make TriggerModelSwaps refuse to ever warm the model,
// even on the largest fleet tier.
func TestDSV4StreamingColdLoadSpillRejectedWithRawDiskSize(t *testing.T) {
	reg := New(testLogger())
	model := "deepseek-v4-flash-4bit"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 141.0, MinRAMGB: dsv4StreamingMinRAMGB}})
	makeDSV4ColdProvider(t, reg, "cold128", model, 128)

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false); n != 0 {
		t.Fatalf("ColdSpillProviders = %d, want 0 (raw on-disk size_gb=141 must never clear the free-for-load gate)", n)
	}
}

// TestDSV4StreamingPredictServableUsesResidentTokenBudgetWhenWarm verifies the
// servability tier-2 (fleet token-budget ceiling) uses the PROVIDER-REPORTED
// live ActiveTokenBudgetMax for a resident DSV4 slot (not any catalog-derived
// estimate) — the authoritative number once the model is actually loaded and
// the expert cache has claimed its share of the unified-memory cap.
func TestDSV4StreamingPredictServableUsesResidentTokenBudgetWhenWarm(t *testing.T) {
	reg := New(testLogger())
	model := "deepseek-v4-flash-4bit"
	reg.SetModelCatalog([]CatalogEntry{dsv4CatalogEntry(model)})
	// Warm 64GB box reporting a real post-load budget (resident + cache leaves
	// room for a representative context window).
	makeDSV4WarmProvider(t, reg, "warm64", model, 64, 40_000)

	verdict := reg.PredictServable(model, 2_000, 2_000, 4_096, 131072, RequestTraits{}, false)
	if !verdict.Servable {
		t.Fatalf("verdict = %+v, want Servable=true (within the reported 40k token budget)", verdict)
	}

	// A request whose prompt+max exceeds the reported LIVE budget must be
	// flagged unservable on this (only) provider.
	verdict = reg.PredictServable(model, 2_000, 2_000, 100_000, 131072, RequestTraits{}, false)
	if verdict.Servable {
		t.Fatalf("verdict = %+v, want Servable=false (102k tokens exceeds the reported 40k budget)", verdict)
	}
}

// TestDSV4StreamingPredictServableColdEstimateWithStreamingSizeIsNonZero proves
// the cold (not-yet-loaded) servability estimate — coldTokenBudgetEstimate,
// which multiplies catalog SizeGB by the padding factor and subtracts it from
// the unified-memory cap — is NOT degenerate (collapsed to zero budget, which
// would wrongly mark the model unservable everywhere) when SizeGB is the
// streaming-aware load-weight instead of the raw 141GB on-disk total.
func TestDSV4StreamingPredictServableColdEstimateWithStreamingSizeIsNonZero(t *testing.T) {
	reg := New(testLogger())
	model := "deepseek-v4-flash-4bit"
	reg.SetModelCatalog([]CatalogEntry{dsv4CatalogEntry(model)})
	makeDSV4ColdProvider(t, reg, "cold36", model, 36)

	verdict := reg.PredictServable(model, 500, 500, 2_048, 131072, RequestTraits{}, false)
	if !verdict.Servable {
		t.Fatalf("verdict = %+v, want Servable=true on a cold 36GB box with the streaming-aware size", verdict)
	}
	if verdict.FleetMaxBudget <= 0 {
		t.Fatalf("FleetMaxBudget = %d, want > 0 (coldTokenBudgetEstimate collapsed to zero — the exact failure mode the raw 141GB size causes)", verdict.FleetMaxBudget)
	}
}

// TestDSV4StreamingPredictServableColdEstimateCollapsesWithRawDiskSize pins the
// "before" failure mode: registering the raw on-disk 141GB total makes the
// cold-provider token-budget estimate collapse to zero on a 36GB box (padded
// weights alone exceed the unified-memory cap), which PredictServable then
// reports as structurally unservable EVEN THOUGH a streaming provider would
// serve it fine once loaded.
func TestDSV4StreamingPredictServableColdEstimateCollapsesWithRawDiskSize(t *testing.T) {
	reg := New(testLogger())
	model := "deepseek-v4-flash-4bit"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 141.0, MinRAMGB: dsv4StreamingMinRAMGB}})
	makeDSV4ColdProvider(t, reg, "cold36-raw", model, 36)

	verdict := reg.PredictServable(model, 500, 500, 2_048, 131072, RequestTraits{}, false)
	if verdict.FleetMaxBudget != 0 {
		t.Fatalf("FleetMaxBudget = %d, want 0 (padded 141GB must exceed the 36GB cap — proving the raw size is unusable)", verdict.FleetMaxBudget)
	}
	if verdict.Servable {
		t.Fatalf("verdict = %+v, want Servable=false — this is the false-negative the streaming-aware override fixes", verdict)
	}
}

// TestDSV4SingleSlotConcurrencyQueuesInsteadOfStorming verifies the coordinator
// respects a sequential-serving provider's self-reported MaxConcurrency=1
// (BatchScheduler.effectiveMaxConcurrentRequests for a
// requiresSequentialServing model like DeepSeek-V4): a second request against
// an already-busy single-slot provider is rejected as a (retryable) capacity
// gate, not dispatched — so the coordinator queues/retries rather than storms
// the sequential runner with a second concurrent request it would reject with
// token_budget_exhausted.
func TestDSV4SingleSlotConcurrencyQueuesInsteadOfStorming(t *testing.T) {
	reg := New(testLogger())
	model := "deepseek-v4-flash-4bit"
	reg.SetModelCatalog([]CatalogEntry{dsv4CatalogEntry(model)})
	p := makeDSV4WarmProvider(t, reg, "seq", model, 64, 40_000)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].NumRunning = 1 // already serving one sequential request
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID: "dsv4-second-concurrent", Model: model, RequestedMaxTokens: 256,
	})
	if selected != nil {
		t.Fatalf("selected %q for a second concurrent request against a MaxConcurrency=1 slot, want nil", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want a single capacity rejection (queue/retry), not model_too_large or silent drop", decision)
	}

	// Once the in-flight request completes (NumRunning back to 0), the next
	// request must be admitted immediately — confirming this is a transient
	// capacity gate the queue drains, not a permanent exclusion.
	p.mu.Lock()
	p.BackendCapacity.Slots[0].NumRunning = 0
	p.mu.Unlock()
	selected, _ = reg.ReserveProviderEx(model, &PendingRequest{
		RequestID: "dsv4-after-completion", Model: model, RequestedMaxTokens: 256,
	})
	if selected == nil || selected.ID != p.ID {
		t.Fatalf("selected = %v after the slot freed up, want provider %q", selected, p.ID)
	}
}

func fmtGB(gb float64) string {
	return fmt.Sprintf("%dGB", int(gb))
}
