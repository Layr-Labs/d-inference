package store

import "testing"

func TestModelRegistryStatusPreservationStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testModelRegistryStatusPreservationStoreContract(t, st)
		})
	}
}

func testModelRegistryStatusPreservationStoreContract(t *testing.T, st Store) {
	t.Helper()

	modelID := uniqueID("retired-model")
	entry := &ModelRegistryEntry{
		ID: modelID, DisplayName: "Active model", Status: "active",
	}
	version := &ModelVersion{
		ModelID: modelID, Version: "1", Status: "ready",
		AggregateSHA256: "aggregate-v1", TotalSizeBytes: 10, FileCount: 1,
	}
	files := []ModelVersionFile{{
		Path: "model.bin", SizeBytes: 10, SHA256: "file-v1", Role: "weights",
	}}
	if err := st.SetModelVersion(entry, version, files); err != nil {
		t.Fatalf("seed model version: %v", err)
	}
	if err := st.PromoteModelVersion(modelID, version.Version); err != nil {
		t.Fatalf("promote model version: %v", err)
	}
	assertModelStatus(t, st, modelID, "active")
	if err := st.SetModelStatus(modelID, "retired"); err != nil {
		t.Fatalf("retire model: %v", err)
	}

	// Metadata refreshes are not lifecycle transitions: an upsert must retain
	// the status already chosen through SetModelStatus.
	if err := st.UpsertModelRegistryEntry(&ModelRegistryEntry{
		ID: modelID, DisplayName: "Refreshed retired model", Status: "active",
	}); err != nil {
		t.Fatalf("refresh retired model: %v", err)
	}
	assertModelUnavailable(t, st, modelID)

	// Registering another manifest version is also metadata/version work, not an
	// implicit reactivation of a model that operators retired.
	nextVersion := &ModelVersion{
		ModelID: modelID, Version: "2", Status: "ready",
		AggregateSHA256: "aggregate-v2", TotalSizeBytes: 20, FileCount: 1,
	}
	if err := st.SetModelVersion(
		&ModelRegistryEntry{ID: modelID, DisplayName: "Versioned retired model", Status: "active"},
		nextVersion,
		[]ModelVersionFile{{Path: "model-v2.bin", SizeBytes: 20, SHA256: "file-v2", Role: "weights"}},
	); err != nil {
		t.Fatalf("register version for retired model: %v", err)
	}
	assertModelUnavailable(t, st, modelID)
}

func assertModelStatus(t *testing.T, st Store, modelID, want string) {
	t.Helper()
	record, err := st.GetModelRegistryRecord(modelID)
	if err != nil {
		t.Fatalf("get model registry record: %v", err)
	}
	if record.Status != want {
		t.Fatalf("model status = %q, want %q", record.Status, want)
	}
}

func assertModelUnavailable(t *testing.T, st Store, modelID string) {
	t.Helper()
	record, err := st.GetModelRegistryRecord(modelID)
	if err == nil || record != nil {
		t.Fatalf("retired model lookup = %+v err=%v, want unavailable", record, err)
	}
}
