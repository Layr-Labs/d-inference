package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Fleet-gate coverage for gemma-4-31b-4bit — the fully-RESIDENT flagship
// (18.4GB on-disk, dense, loaded whole into memory). Unlike DeepSeek-V4
// (deepseek_v4_streaming_test.go), this model needs NO catalog_size_gb
// override: the raw manifest total IS the resident weight footprint, so the
// default SyncModelCatalog registration (SizeGB=TotalSizeBytes/1e9) is
// correct. These tests pin the recommended registration — SizeGB=18.4,
// MinRAMGB=32 — across the fleet tiers, and pin the floor rationale:
// reportedFreeForLoadAdmits needs SizeGB×~1.1176 ≤ 0.9×RAM−reserve, which
// clears at 32GB (24.8 ≥ 20.6) and fails at 24GB (17.6 < 20.6).
const (
	gemma31bSizeGB   = 18.4
	gemma31bMinRAMGB = 32
)

func gemma31bCatalogEntry(model string) CatalogEntry {
	return CatalogEntry{ID: model, SizeGB: gemma31bSizeGB, MinRAMGB: gemma31bMinRAMGB}
}

// makeGemma31bColdProvider mirrors makeDSV4ColdProvider: the model is
// advertised but not loaded, FreeForLoadGB is the realistic idle-box value
// for the tier (90% unified-memory cap minus OS/operator reserve).
func makeGemma31bColdProvider(t *testing.T, reg *Registry, id, model string, totalMemGB float64) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Hardware.MemoryGB = int(totalMemGB)
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "gemma4", Quantization: "4bit", SizeBytes: 18_400_000_000}}
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

// TestGemma31bResidentAdmitsColdLoadAcrossFleetSizes: with the default
// (non-overridden) registration, a cold provider on every viable tier must
// clear both the structural gate and the free-for-load gate.
func TestGemma31bResidentAdmitsColdLoadAcrossFleetSizes(t *testing.T) {
	model := "gemma-4-31b-4bit"
	for _, totalMemGB := range []float64{32, 36, 48, 64, 96, 128} {
		t.Run(fmtGB(totalMemGB), func(t *testing.T) {
			reg := New(testLogger())
			reg.SetModelCatalog([]CatalogEntry{gemma31bCatalogEntry(model)})
			makeGemma31bColdProvider(t, reg, "p", model, totalMemGB)

			candidates, capacityRejections, tooLarge := reg.QuickCapacityCheck(model, 500, 256, RequestTraits{})
			if tooLarge != 0 {
				t.Fatalf("%.0fGB box: modelTooLarge=%d, want 0 (min_ram_gb=%d must admit)", totalMemGB, tooLarge, gemma31bMinRAMGB)
			}
			if candidates != 1 || capacityRejections != 0 {
				t.Fatalf("%.0fGB box: candidates=%d capacityRejections=%d, want 1/0 (resident size_gb=%.1f must fit free-for-load)",
					totalMemGB, candidates, capacityRejections, gemma31bSizeGB)
			}

			p := reg.GetProvider("p")
			selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
				RequestID: "gemma31b-cold-" + fmtGB(totalMemGB), Model: model, RequestedMaxTokens: 256,
			})
			if selected == nil || selected.ID != p.ID {
				t.Fatalf("%.0fGB box: ReserveProviderEx selected=%v decision=%+v, want provider %q", totalMemGB, selected, decision, p.ID)
			}
		})
	}
}

// TestGemma31bResidentRejectsBelowMinRAM: a 24GB box must be excluded as
// model_too_large — and the free-for-load math agrees (17.6 < 20.6), so the
// structural floor and the memory gate give a consistent verdict.
func TestGemma31bResidentRejectsBelowMinRAM(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-31b-4bit"
	reg.SetModelCatalog([]CatalogEntry{gemma31bCatalogEntry(model)})
	makeGemma31bColdProvider(t, reg, "tiny", model, 24)

	candidates, capacityRejections, tooLarge := reg.QuickCapacityCheck(model, 500, 256, RequestTraits{})
	if tooLarge != 1 || candidates != 0 || capacityRejections != 0 {
		t.Fatalf("24GB box: (cand=%d, capRej=%d, tooLarge=%d), want (0,0,1)", candidates, capacityRejections, tooLarge)
	}
}

// TestGemma31bResidentColdLoadSpillEligible: TriggerModelSwaps' cold-spill
// predicate must accept an idle fitting provider at the floor tier, so the
// warm-pool planner can pre-warm gemma-4-31b on 32GB boxes.
func TestGemma31bResidentColdLoadSpillEligible(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-31b-4bit"
	reg.SetModelCatalog([]CatalogEntry{gemma31bCatalogEntry(model)})
	makeGemma31bColdProvider(t, reg, "cold32", model, 32)

	if n := reg.ColdSpillProviders(model, RequestTraits{}, false); n != 1 {
		t.Fatalf("ColdSpillProviders = %d, want 1 (18.4GB resident must clear the cold-load gate on a 32GB box)", n)
	}
}
