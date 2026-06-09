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
