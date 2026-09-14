package ingress

import (
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inferencefixture"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// publishTestModels installs the active records and aliases seeded by these
// private policy fixtures. The authenticated API catalog publication paths
// retain their API integration tests.
func publishTestModels(t testing.TB, reg *registry.Registry, st store.Store) {
	t.Helper()
	rows, err := st.ListActiveModelRegistryWithError()
	if err != nil {
		t.Fatal(err)
	}
	entries := make([]registry.CatalogEntry, 0, len(rows))
	for _, row := range rows {
		if row.ActiveVersion == nil {
			continue
		}
		entries = append(entries, registry.CatalogEntry{
			ID: row.ID, WeightHash: row.ActiveVersion.AggregateSHA256,
			SizeGB:                       float64(row.ActiveVersion.TotalSizeBytes) / 1e9,
			MinRAMGB:                     row.MinRAMGB,
			RequiredProviderCapabilities: append([]string{}, row.RequiredProviderCapabilities...),
		})
	}
	reg.SetModelCatalog(entries)
	rowsAlias, err := st.ListModelAliases()
	if err != nil {
		t.Fatal(err)
	}
	aliases := make(map[string]registry.AliasTarget, len(rowsAlias))
	for _, row := range rowsAlias {
		aliases[row.AliasID] = registry.AliasTarget{Desired: row.DesiredBuild, Previous: row.PreviousBuild, Retired: row.RetiredBuilds}
	}
	reg.SetModelAliases(aliases)
}

func newBenchController(t testing.TB) (*Controller, *registry.Registry, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	inferencefixture.SeedModel(t, st, inferencefixture.DesiredBuild, map[string]any{
		"reasoning_parser": "qwen3", "tool_call_parser": "qwen3_coder",
	})
	inferencefixture.SeedModel(t, st, inferencefixture.PreviousBuild, nil)
	reg := registry.New(logger)
	c := newTestController(testServices{registry: reg, store: st, logger: logger, firstContentDeadlineBase: 5 * time.Second})
	publishTestModels(t, reg, st)
	reg.SetModelAliases(map[string]registry.AliasTarget{
		inferencefixture.Alias: {Desired: inferencefixture.DesiredBuild, Previous: inferencefixture.PreviousBuild},
	})
	return c, reg, st
}

// Alias-unit fixtures supply the operator policy through its production
// dependency. Current Server.SetRejectModels bindings have real-route tests.
func setTestRejectedModels(c *Controller, models map[string]bool) {
	c.deps.ModelShed = func(resolved, requested string) bool { return models[resolved] || models[requested] }
}
