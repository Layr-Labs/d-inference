package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// registerModelContext registers modelID in the store with a known context window
// so the dispatch path's modelMaxContext is populated (it reads
// store.GetModelRegistryRecord(model).MaxContextLength). The record is only
// returned when an active+ready version exists, so set+promote a minimal one.
func registerModelContext(t *testing.T, st *memory.MemoryStore, modelID string, ctxLen int) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: modelID, Quantization: "4bit",
		MaxContextLength: ctxLen, MaxOutputLength: 8192, MinRAMGB: 8,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: modelID, Version: "v1", R2Prefix: testModelPrefix(modelID, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		t.Fatalf("SetModelVersion: %v", err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatalf("PromoteModelVersion: %v", err)
	}
}

// setProviderModelBudget stamps a per-model reported token budget on a provider so
// the dispatch path can read it (ReportedTokenBudgetMaxForModel) when classifying a
// "batch token budget" rejection. Written under the provider mutex — the same lock
// the reader takes.
func setProviderModelBudget(t *testing.T, reg *registry.Registry, registryID, model string, budgetMax int64) {
	t.Helper()
	p := reg.GetProvider(registryID)
	if p == nil {
		t.Fatalf("provider %q missing", registryID)
	}
	p.Mu().Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		Slots: []protocol.BackendSlotCapacity{{
			Model: model, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: budgetMax,
		}},
	}
	p.Mu().Unlock()
}
