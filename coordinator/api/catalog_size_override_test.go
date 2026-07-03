package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestCatalogSizeGBForRowDefaultsToOnDiskTotal is the non-streaming byte-for-byte
// guarantee: a model registry row with no "catalog_size_gb" override must
// produce EXACTLY the historical value (TotalSizeBytes/1e9), regardless of
// what else is in RuntimeParameters.
func TestCatalogSizeGBForRowDefaultsToOnDiskTotal(t *testing.T) {
	cases := []struct {
		name  string
		runtP map[string]any
	}{
		{"nil runtime_parameters", nil},
		{"empty runtime_parameters", map[string]any{}},
		{"unrelated runtime_parameters", map[string]any{"reasoning_parser": "deepseek"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			row := store.ModelRegistryRecord{
				ModelRegistryEntry: store.ModelRegistryEntry{ID: "some-model", RuntimeParameters: tc.runtP},
				ActiveVersion:      &store.ModelVersion{TotalSizeBytes: 12_100_000_000},
			}
			got := catalogSizeGBForRow(row)
			want := 12.1
			if got != want {
				t.Fatalf("catalogSizeGBForRow = %v, want %v (byte-for-byte historical behavior)", got, want)
			}
		})
	}
}

// TestCatalogSizeGBForRowHonorsStreamingOverride proves the DeepSeek-V4
// streaming fix: a positive "catalog_size_gb" RuntimeParameters override wins
// over the raw 141GB on-disk manifest total.
func TestCatalogSizeGBForRowHonorsStreamingOverride(t *testing.T) {
	row := store.ModelRegistryRecord{
		ModelRegistryEntry: store.ModelRegistryEntry{
			ID:                "deepseek-v4-flash-4bit",
			RuntimeParameters: map[string]any{"catalog_size_gb": 16.0},
		},
		ActiveVersion: &store.ModelVersion{TotalSizeBytes: 141_000_000_000},
	}
	got := catalogSizeGBForRow(row)
	if got != 16.0 {
		t.Fatalf("catalogSizeGBForRow = %v, want 16 (override must win over the 141GB on-disk total)", got)
	}
}

// TestCatalogSizeGBForRowIgnoresNonPositiveOrNonNumericOverride guards against
// an operator typo (0, negative, or a non-numeric value) silently disabling the
// memory-admission gate or crashing the sync.
func TestCatalogSizeGBForRowIgnoresNonPositiveOrNonNumericOverride(t *testing.T) {
	for _, override := range []any{0.0, -5.0, "16", nil} {
		row := store.ModelRegistryRecord{
			ModelRegistryEntry: store.ModelRegistryEntry{
				ID:                "bad-override-model",
				RuntimeParameters: map[string]any{"catalog_size_gb": override},
			},
			ActiveVersion: &store.ModelVersion{TotalSizeBytes: 20_000_000_000},
		}
		got := catalogSizeGBForRow(row)
		if got != 20.0 {
			t.Fatalf("override=%v: catalogSizeGBForRow = %v, want fallback to on-disk total (20)", override, got)
		}
	}
}

// TestCatalogSizeGBForRowAcceptsIntOverride covers the Go-literal-int shape
// (as opposed to the float64 a JSON round-trip through Postgres produces) —
// both must work since RuntimeParameters is a bare map[string]any.
func TestCatalogSizeGBForRowAcceptsIntOverride(t *testing.T) {
	row := store.ModelRegistryRecord{
		ModelRegistryEntry: store.ModelRegistryEntry{
			ID:                "int-override-model",
			RuntimeParameters: map[string]any{"catalog_size_gb": 16},
		},
		ActiveVersion: &store.ModelVersion{TotalSizeBytes: 141_000_000_000},
	}
	if got := catalogSizeGBForRow(row); got != 16.0 {
		t.Fatalf("catalogSizeGBForRow = %v, want 16 (int override must be honored)", got)
	}
}

// TestSyncModelCatalogAppliesStreamingOverrideEndToEnd exercises the full
// SyncModelCatalog path (store -> registry.CatalogEntry) so the override is
// proven wired all the way through, not just at the helper-function level.
func TestSyncModelCatalogAppliesStreamingOverrideEndToEnd(t *testing.T) {
	srv, st := testServer(t)

	const model = "deepseek-v4-flash-4bit"
	entry := &store.ModelRegistryEntry{
		ID: model, DisplayName: "DeepSeek V4 Flash 4bit", Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 32768, MinRAMGB: 36, Status: "active",
		RuntimeParameters: map[string]any{"catalog_size_gb": 16.0},
	}
	version := &store.ModelVersion{
		ModelID: model, Version: "v1", R2Prefix: modelR2Prefix(model, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 141_000_000_000, FileCount: 1, Status: "ready",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, version, files); err != nil {
		t.Fatalf("SetModelVersion: %v", err)
	}
	if err := st.PromoteModelVersion(model, "v1"); err != nil {
		t.Fatalf("PromoteModelVersion: %v", err)
	}

	srv.SyncModelCatalog()

	if !srv.registry.IsModelInCatalog(model) {
		t.Fatalf("expected %q in catalog after sync", model)
	}

	// modelFitsHardware(min_ram_gb=36, ...) must reject a 24GB box — proving
	// MinRAMGB (an independently operator-set field, unaffected by the SizeGB
	// override) is still the structural gate. A legacy-shaped provider (no
	// BackendCapacity) exercises the Hardware.MemoryGB fallback path directly.
	small := srv.registry.Register("dsv4-too-small", nil, &protocol.RegisterMessage{
		Hardware:                protocol.Hardware{MemoryGB: 24, MemoryAvailableGB: 20},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "deepseek_v4", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true, TextProxyDisabled: true, PythonRuntimeLocked: true,
			DangerousModulesBlocked: true, SIPEnabled: true, AntiDebugEnabled: true,
			CoreDumpsDisabled: true, EnvScrubbed: true,
		},
	})
	small.Mu().Lock()
	small.TrustLevel = registry.TrustHardware
	small.RuntimeVerified = true
	small.RuntimeManifestChecked = true
	small.ChallengeVerifiedSIP = true
	small.LastChallengeVerified = time.Now()
	small.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	small.Mu().Unlock()

	candidates, capacityRejections, tooLarge := srv.registry.QuickCapacityCheck(model, 500, 256, registry.RequestTraits{})
	if tooLarge != 1 {
		t.Fatalf("QuickCapacityCheck = (cand=%d, capRej=%d, tooLarge=%d), want (0,0,1) (24GB box below min_ram_gb=36)", candidates, capacityRejections, tooLarge)
	}
}
