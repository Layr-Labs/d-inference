package store

import "testing"

func TestMemoryModelMigrationRoundTrip(t *testing.T) {
	st := NewMemory(Config{})

	m := &ModelMigration{
		AliasID:        "gemma-4-26b",
		FromBuild:      "mlx-community/gemma-4-26b-a4b-it-fp8",
		ToBuild:        "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
		BatchSize:      2,
		MaxStepPercent: 20,
		Status:         MigrationActive,
	}
	if err := st.UpsertModelMigration(m); err != nil {
		t.Fatal(err)
	}

	got, ok, err := st.GetModelMigration("gemma-4-26b")
	if err != nil || !ok {
		t.Fatalf("get: ok=%v err=%v", ok, err)
	}
	if got.ToBuild != m.ToBuild || got.BatchSize != 2 || got.Status != MigrationActive {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	if got.CreatedAt.IsZero() || got.UpdatedAt.IsZero() {
		t.Fatalf("timestamps not set: %+v", got)
	}

	// Returned value is a copy: mutating it must not affect stored state.
	got.Status = MigrationComplete
	again, _, _ := st.GetModelMigration("gemma-4-26b")
	if again.Status != MigrationActive {
		t.Fatalf("stored migration mutated through returned copy: %s", again.Status)
	}

	// Upsert preserves CreatedAt while updating status.
	created := again.CreatedAt
	m.Status = MigrationComplete
	if err := st.UpsertModelMigration(m); err != nil {
		t.Fatal(err)
	}
	upd, _, _ := st.GetModelMigration("gemma-4-26b")
	if upd.Status != MigrationComplete {
		t.Fatalf("status not updated: %s", upd.Status)
	}
	if !upd.CreatedAt.Equal(created) {
		t.Fatal("CreatedAt should be preserved across upsert")
	}

	list, err := st.ListModelMigrations()
	if err != nil || len(list) != 1 {
		t.Fatalf("list = %d err=%v", len(list), err)
	}

	if err := st.DeleteModelMigration("gemma-4-26b"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := st.GetModelMigration("gemma-4-26b"); ok {
		t.Fatal("migration still present after delete")
	}
}

func TestMemoryModelMigrationMissing(t *testing.T) {
	st := NewMemory(Config{})
	if _, ok, err := st.GetModelMigration("nope"); ok || err != nil {
		t.Fatalf("missing migration: ok=%v err=%v", ok, err)
	}
}
