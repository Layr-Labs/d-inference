package store

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func testModelRevisionLifecycle(t *testing.T, st Store) {
	t.Helper()
	id := fmt.Sprintf("revision-lifecycle-%s-%d", t.Name(), time.Now().UnixNano())
	entry, a, files := registryFixture(id, "a")
	if err := st.SetModelVersion(entry, a, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(id, "a"); err != nil {
		t.Fatal(err)
	}
	_, b, _ := registryFixture(id, "b")
	b.AggregateSHA256 = strings.Repeat("b", 64)
	if err := st.SetExistingModelVersion(b, files); err != nil {
		t.Fatal(err)
	}
	before, err := st.GetModelRegistryRecord(id)
	if err != nil {
		t.Fatal(err)
	}
	if len(before.ServingVersions) != 1 {
		t.Fatalf("unpromoted bytes became servable: %+v", before.ServingVersions)
	}
	if err := st.PromoteModelVersion(id, "b"); err != nil {
		t.Fatal(err)
	}
	after, err := st.GetModelRegistryRecord(id)
	if err != nil {
		t.Fatal(err)
	}
	if after.ActiveVersion.Version != "b" || len(after.ServingVersions) != 2 {
		t.Fatalf("promotion did not retain approved rollback: %+v", after)
	}
	after.ServingVersions[0].AggregateSHA256 = "mutated"
	again, err := st.GetModelRegistryRecord(id)
	if err != nil || again.ServingVersions[0].AggregateSHA256 == "mutated" {
		t.Fatal("serving version cache is aliased", err)
	}
	b.AggregateSHA256 = strings.Repeat("c", 64)
	if err := st.SetModelVersion(entry, b, files); !errors.Is(err, ErrModelVersionImmutable) {
		t.Fatalf("mutable artifact accepted: %v", err)
	}
	if err := st.RetireModelVersion(id, "b"); !errors.Is(err, ErrActiveModelVersion) {
		t.Fatal("retired desired revision", err)
	}
	if err := st.PromoteModelVersion(id, "a"); err != nil {
		t.Fatal(err)
	}
	rolled, err := st.GetModelRegistryRecord(id)
	if err != nil || rolled.ActiveVersion.Version != "a" || len(rolled.ServingVersions) != 2 {
		t.Fatal("rollback lost serving history", err)
	}
	if err := st.RetireModelVersion(id, "b"); err != nil {
		t.Fatal(err)
	}
	retired, err := st.GetModelRegistryRecord(id)
	if err != nil || len(retired.ServingVersions) != 1 {
		t.Fatal("retired revision remained cached", err)
	}
	if err := st.PromoteModelVersion(id, "b"); err == nil {
		t.Fatal("retired revision promoted without re-registration")
	}
	renamed := append([]ModelVersionFile(nil), files...)
	renamed[0].Path = "different.json"
	if err := st.SetModelVersion(entry, a, renamed); !errors.Is(err, ErrModelVersionImmutable) {
		t.Fatal("manifest file names were mutable", err)
	}
}

func TestMemoryModelRevisionLifecycle(t *testing.T) {
	testModelRevisionLifecycle(t, NewMemory(Config{}))
}
func TestCachedModelRevisionLifecycle(t *testing.T) {
	testModelRevisionLifecycle(t, NewCached(NewMemory(Config{}), DefaultCacheConfig()))
}
func TestPostgresModelRevisionLifecycle(t *testing.T) {
	testModelRevisionLifecycle(t, testPostgresStore(t))
}
