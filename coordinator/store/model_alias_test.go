package store

import "testing"

func TestMemoryModelAliasRoundTrip(t *testing.T) {
	st := NewMemory(Config{})

	alias := &ModelAlias{
		AliasID:       "gemma-4-26b",
		DisplayName:   "Gemma 4 26B",
		DesiredBuild:  "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
		PreviousBuild: "mlx-community/gemma-4-26b-a4b-it-fp8",
		Active:        true,
	}
	if err := st.UpsertModelAlias(alias); err != nil {
		t.Fatal(err)
	}

	got, ok, err := st.GetModelAlias("gemma-4-26b")
	if err != nil || !ok {
		t.Fatalf("get: ok=%v err=%v", ok, err)
	}
	if got.DisplayName != "Gemma 4 26B" {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	if got.DesiredBuild != "mlx-community/gemma-4-26B-A4B-it-qat-4bit" {
		t.Fatalf("desired_build mismatch: %q", got.DesiredBuild)
	}
	if got.PreviousBuild != "mlx-community/gemma-4-26b-a4b-it-fp8" {
		t.Fatalf("previous_build mismatch: %q", got.PreviousBuild)
	}
	if got.CreatedAt.IsZero() || got.UpdatedAt.IsZero() {
		t.Fatalf("timestamps not set: %+v", got)
	}

	// Mutating the returned copy must not affect stored state (deep copy).
	got.DesiredBuild = "tampered"
	again, _, _ := st.GetModelAlias("gemma-4-26b")
	if again.DesiredBuild != "mlx-community/gemma-4-26B-A4B-it-qat-4bit" {
		t.Fatalf("stored alias was mutated through returned copy: %q", again.DesiredBuild)
	}

	// Upsert is idempotent and updates fields while preserving CreatedAt. This is
	// also the revert path: re-PUT with the pointers swapped back.
	created := got.CreatedAt
	alias.DisplayName = "Gemma 4 26B (updated)"
	alias.DesiredBuild = "mlx-community/gemma-4-26b-a4b-it-fp8" // revert to old build
	alias.PreviousBuild = ""
	if err := st.UpsertModelAlias(alias); err != nil {
		t.Fatal(err)
	}
	upd, _, _ := st.GetModelAlias("gemma-4-26b")
	if upd.DisplayName != "Gemma 4 26B (updated)" {
		t.Fatalf("display name not updated: %q", upd.DisplayName)
	}
	if upd.DesiredBuild != "mlx-community/gemma-4-26b-a4b-it-fp8" || upd.PreviousBuild != "" {
		t.Fatalf("revert not persisted: desired=%q previous=%q", upd.DesiredBuild, upd.PreviousBuild)
	}
	if !upd.CreatedAt.Equal(created) {
		t.Fatalf("CreatedAt should be preserved across upsert")
	}

	list, err := st.ListModelAliases()
	if err != nil || len(list) != 1 {
		t.Fatalf("list = %d err=%v", len(list), err)
	}

	if err := st.DeleteModelAlias("gemma-4-26b"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := st.GetModelAlias("gemma-4-26b"); ok {
		t.Fatal("alias still present after delete")
	}
}

func TestMemoryModelAliasMissing(t *testing.T) {
	st := NewMemory(Config{})
	if _, ok, err := st.GetModelAlias("nope"); ok || err != nil {
		t.Fatalf("missing alias: ok=%v err=%v", ok, err)
	}
}

// RetiredBuilds round-trips through the memory store and the stored slice is
// isolated from caller mutation (clone semantics).
func TestModelAliasRetiredBuildsRoundTripAndIsolation(t *testing.T) {
	st := NewMemory(Config{})
	alias := &ModelAlias{
		AliasID:       "gemma-4-26b",
		DesiredBuild:  "qat",
		RetiredBuilds: []string{"fp8", "fp16"},
		Active:        true,
	}
	if err := st.UpsertModelAlias(alias); err != nil {
		t.Fatal(err)
	}
	// Mutating the caller's slice after upsert must not affect stored state.
	alias.RetiredBuilds[0] = "mutated"

	got, found, err := st.GetModelAlias("gemma-4-26b")
	if err != nil || !found {
		t.Fatalf("get: found=%v err=%v", found, err)
	}
	if len(got.RetiredBuilds) != 2 || got.RetiredBuilds[0] != "fp8" || got.RetiredBuilds[1] != "fp16" {
		t.Fatalf("retired builds = %v, want [fp8 fp16]", got.RetiredBuilds)
	}
	// Mutating the returned slice must not affect stored state either.
	got.RetiredBuilds[1] = "mutated"
	again, _, _ := st.GetModelAlias("gemma-4-26b")
	if again.RetiredBuilds[1] != "fp16" {
		t.Fatalf("stored retired builds mutated through returned copy: %v", again.RetiredBuilds)
	}

	listed, err := st.ListModelAliases()
	if err != nil || len(listed) != 1 {
		t.Fatalf("list: %v err=%v", listed, err)
	}
	if len(listed[0].RetiredBuilds) != 2 {
		t.Fatalf("list retired builds = %v", listed[0].RetiredBuilds)
	}
}
