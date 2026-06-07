package api

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// registerProvider advertises the given builds from a provider (online).
func registerBuildsProvider(srv *Server, id string, builds ...string) {
	models := make([]protocol.ModelInfo, 0, len(builds))
	for _, b := range builds {
		models = append(models, protocol.ModelInfo{ID: b, ModelType: "chat", Quantization: "4bit"})
	}
	srv.registry.Register(id, nil, &protocol.RegisterMessage{Models: models})
}

// Directly construct the dangerous window the ramp can briefly create: the new
// build carries a high routing weight but NO provider serves it yet. The
// resolution guard must still never hand traffic to it (it falls back to the
// build that has live capacity), so the public alias never black-holes.
func TestResolveNeverBlackHolesDuringRamp(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	seedActiveModel(t, st, fp8, "fp8")
	seedActiveModel(t, st, qat, "qat")

	// Only fp8 has a live provider; qat is "ramping" at weight 60 with none.
	registerBuildsProvider(srv, "p1", fp8)
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		Builds: []store.ModelAliasBuild{
			{BuildID: fp8, Weight: 40, Active: true},
			{BuildID: qat, Weight: 60, Active: true},
		},
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	for i := 0; i < 200; i++ {
		build, _, ok := reg.ResolveModel("gemma-4-26b")
		if !ok {
			t.Fatal("alias failed to resolve")
		}
		if build != fp8 {
			t.Fatalf("resolved to %q which has no serving provider — black-hole during ramp", build)
		}
	}
}

// The headline guarantee: while the migration controller ramps an alias from
// fp8 to qat-4bit — with providers finishing their background prefetch and
// re-advertising the new build over time — every resolution of the public alias
// lands on a build that has a live provider. The consumer-facing name never
// changes and traffic never black-holes. At convergence all traffic is on qat
// and the migration completes.
func TestZeroDowntimeAliasMigration(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	seedActiveModel(t, st, fp8, "fp8")
	seedActiveModel(t, st, qat, "qat")

	// Three providers serving the old build; alias points entirely at fp8.
	providers := []string{"p1", "p2", "p3"}
	for _, p := range providers {
		registerBuildsProvider(srv, p, fp8)
	}
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		Builds: []store.ModelAliasBuild{{BuildID: fp8, Weight: 100, Active: true}},
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	// Start the migration fp8 → qat.
	if err := st.UpsertModelMigration(&store.ModelMigration{
		AliasID: "gemma-4-26b", FromBuild: fp8, ToBuild: qat,
		BatchSize: 1, MaxStepPercent: 40, Status: store.MigrationActive,
	}); err != nil {
		t.Fatal(err)
	}
	mc := newMigrationController(srv)

	servingProviders := func(build string) bool {
		return len(reg.ProvidersServingBuild(build)) > 0
	}
	// Invariant check: many resolutions, each must hit a build with live capacity.
	assertNoBlackHole := func(tick int) {
		for i := 0; i < 100; i++ {
			build, isAlias, ok := reg.ResolveModel("gemma-4-26b")
			if !isAlias || !ok {
				t.Fatalf("tick %d: alias failed to resolve (isAlias=%v ok=%v)", tick, isAlias, ok)
			}
			if !servingProviders(build) {
				t.Fatalf("tick %d: resolved to %q which has no serving provider (black-hole!)", tick, build)
			}
		}
	}

	migrated := 0
	completed := false
	for tick := 0; tick < 40; tick++ {
		assertNoBlackHole(tick)

		mig, ok, _ := st.GetModelMigration("gemma-4-26b")
		if !ok {
			t.Fatal("migration disappeared")
		}
		if mig.Status == store.MigrationComplete {
			completed = true
			break
		}
		mc.runMigration(*mig)

		// Simulate one more provider finishing its background prefetch: the
		// real production signal is prefetch_model_status:verified, which the
		// coordinator turns into an in-place advertise via MarkBuildPrefetched
		// (the provider keeps serving the old build throughout).
		if migrated < len(providers) {
			reg.MarkBuildPrefetched(providers[migrated], qat)
			migrated++
		}
	}
	assertNoBlackHole(99)

	if !completed {
		t.Fatalf("migration did not complete; final to-weight unknown")
	}
	// After completion the old build is fully drained (weight 0) and qat is 100.
	alias, _, _ := st.GetModelAlias("gemma-4-26b")
	if buildWeight(alias, qat) != 100 {
		t.Fatalf("qat weight = %d, want 100", buildWeight(alias, qat))
	}
	if buildWeight(alias, fp8) != 0 {
		t.Fatalf("fp8 weight = %d, want 0 (drained)", buildWeight(alias, fp8))
	}
	// With fp8 drained, every resolution now lands on qat.
	for i := 0; i < 50; i++ {
		if build, _, _ := reg.ResolveModel("gemma-4-26b"); build != qat {
			t.Fatalf("post-migration resolve = %q, want qat", build)
		}
	}
}
