package store

import "testing"

func TestMemoryModelAliasRoundTrip(t *testing.T) {
	st := NewMemory(Config{})

	alias := &ModelAlias{
		AliasID:     "gemma-4-26b",
		DisplayName: "Gemma 4 26B",
		Builds: []ModelAliasBuild{
			{BuildID: "mlx-community/gemma-4-26b-a4b-it-fp8", Weight: 30, Active: true},
			{BuildID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit", Weight: 70, Active: true},
		},
		Active: true,
	}
	if err := st.UpsertModelAlias(alias); err != nil {
		t.Fatal(err)
	}

	got, ok, err := st.GetModelAlias("gemma-4-26b")
	if err != nil || !ok {
		t.Fatalf("get: ok=%v err=%v", ok, err)
	}
	if got.DisplayName != "Gemma 4 26B" || len(got.Builds) != 2 {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	if got.CreatedAt.IsZero() || got.UpdatedAt.IsZero() {
		t.Fatalf("timestamps not set: %+v", got)
	}

	// Mutating the returned copy must not affect stored state (deep copy).
	got.Builds[0].Weight = 999
	again, _, _ := st.GetModelAlias("gemma-4-26b")
	if again.Builds[0].Weight != 30 {
		t.Fatalf("stored alias was mutated through returned copy: %d", again.Builds[0].Weight)
	}

	// Upsert is idempotent and updates fields while preserving CreatedAt.
	created := got.CreatedAt
	alias.DisplayName = "Gemma 4 26B (updated)"
	if err := st.UpsertModelAlias(alias); err != nil {
		t.Fatal(err)
	}
	upd, _, _ := st.GetModelAlias("gemma-4-26b")
	if upd.DisplayName != "Gemma 4 26B (updated)" {
		t.Fatalf("display name not updated: %q", upd.DisplayName)
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
