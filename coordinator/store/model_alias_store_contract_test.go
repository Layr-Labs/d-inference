package store

import "testing"

func TestModelAliasStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testModelAliasStoreContract(t, st)
		})
	}
}

func testModelAliasStoreContract(t *testing.T, st Store) {
	t.Helper()

	if _, ok, err := st.GetModelAlias("missing"); ok || err != nil {
		t.Fatalf("missing alias: ok=%v err=%v", ok, err)
	}

	alias := &ModelAlias{
		AliasID:        uniqueID("alias"),
		DisplayName:    "Gemma 4 26B",
		OpenRouterOnly: true,
		SourceModel:    "gemma-4-26b-source",
		SourceKind:     ModelAliasSourceAlias,
		OpenRouterSlug: "google/gemma-4-26b-it",
		HuggingFaceID:  "google/gemma-4-26b-it",
		DesiredBuild:   "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
		PreviousBuild:  "mlx-community/gemma-4-26b-a4b-it-fp8",
		RetiredBuilds:  []string{"fp8", "fp16"},
		Active:         true,
	}
	if err := st.UpsertModelAlias(alias); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	alias.RetiredBuilds[0] = "caller-mutated"

	got, ok, err := st.GetModelAlias(alias.AliasID)
	if err != nil || !ok {
		t.Fatalf("get: ok=%v err=%v", ok, err)
	}
	if got.DisplayName != alias.DisplayName ||
		got.DesiredBuild != "mlx-community/gemma-4-26B-A4B-it-qat-4bit" ||
		got.PreviousBuild != "mlx-community/gemma-4-26b-a4b-it-fp8" ||
		!got.OpenRouterOnly ||
		got.SourceModel != alias.SourceModel ||
		got.SourceKind != ModelAliasSourceAlias ||
		got.OpenRouterSlug != alias.OpenRouterSlug ||
		got.HuggingFaceID != alias.HuggingFaceID {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	if got.CreatedAt.IsZero() || got.UpdatedAt.IsZero() {
		t.Fatalf("timestamps not set: %+v", got)
	}
	if len(got.RetiredBuilds) != 2 || got.RetiredBuilds[0] != "fp8" || got.RetiredBuilds[1] != "fp16" {
		t.Fatalf("retired builds = %v, want [fp8 fp16]", got.RetiredBuilds)
	}

	created := got.CreatedAt
	got.DesiredBuild = "returned-copy-mutated"
	got.RetiredBuilds[1] = "returned-copy-mutated"
	again, _, err := st.GetModelAlias(alias.AliasID)
	if err != nil {
		t.Fatalf("get after returned-copy mutation: %v", err)
	}
	if again.DesiredBuild != "mlx-community/gemma-4-26B-A4B-it-qat-4bit" ||
		again.RetiredBuilds[1] != "fp16" {
		t.Fatalf("stored alias was mutated through returned copy: %+v", again)
	}

	alias.DisplayName = "Gemma 4 26B (updated)"
	alias.DesiredBuild = "mlx-community/gemma-4-26b-a4b-it-fp8"
	alias.PreviousBuild = ""
	alias.RetiredBuilds = []string{"fp16"}
	if err := st.UpsertModelAlias(alias); err != nil {
		t.Fatalf("update: %v", err)
	}
	updated, ok, err := st.GetModelAlias(alias.AliasID)
	if err != nil || !ok {
		t.Fatalf("get updated: ok=%v err=%v", ok, err)
	}
	if updated.DisplayName != alias.DisplayName ||
		updated.DesiredBuild != alias.DesiredBuild ||
		updated.PreviousBuild != "" ||
		len(updated.RetiredBuilds) != 1 ||
		updated.RetiredBuilds[0] != "fp16" {
		t.Fatalf("update mismatch: %+v", updated)
	}
	if !updated.CreatedAt.Equal(created) {
		t.Fatalf("created_at changed across upsert: got %v want %v", updated.CreatedAt, created)
	}

	list, err := st.ListModelAliases()
	if err != nil || len(list) != 1 || list[0].AliasID != alias.AliasID {
		t.Fatalf("list = %+v err=%v", list, err)
	}
	if err := st.DeleteModelAlias(alias.AliasID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, ok, err := st.GetModelAlias(alias.AliasID); ok || err != nil {
		t.Fatalf("alias present after delete: ok=%v err=%v", ok, err)
	}
}
