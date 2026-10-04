package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func testModelRevisionPreservesOriginalPublisher(t *testing.T, st store.Store) {
	t.Helper()
	for _, publisher := range []string{"original-publishing-key", ""} {
		t.Run("publisher="+publisher, func(t *testing.T) {
			entry, original, files := registryFixture(uniqueID("publisher"), "v1")
			original.UploadedBy = publisher
			if err := st.SetModelVersion(entry, original, files); err != nil {
				t.Fatal(err)
			}
			if err := st.PromoteModelVersion(entry.ID, original.Version); err != nil {
				t.Fatal(err)
			}
			// Prime read-through caches before either publication path retries.
			before, err := st.GetModelRegistryRecord(entry.ID)
			if err != nil {
				t.Fatal(err)
			}
			for _, register := range []bool{true, false} {
				retry := *before.ActiveVersion
				retry.UploadedBy = "another-publishing-key"
				retry.UploadedAt = retry.UploadedAt.Add(time.Hour)
				if register {
					err = st.SetModelVersion(entry, &retry, files)
				} else {
					err = st.SetExistingModelVersion(&retry, files)
				}
				if err != nil {
					t.Fatal(err)
				}
				after, err := st.GetModelRegistryRecord(entry.ID)
				if err != nil {
					t.Fatal(err)
				}
				for _, version := range []*store.ModelVersion{after.ActiveVersion, &retry} {
					if version.UploadedBy != publisher || !version.UploadedAt.Equal(before.ActiveVersion.UploadedAt) {
						t.Fatalf("retry replaced original provenance (register=%t): got %q at %s, want %q at %s",
							register, version.UploadedBy, version.UploadedAt, publisher, before.ActiveVersion.UploadedAt)
					}
				}
			}
		})
	}
}

func TestMemoryModelRevisionPreservesOriginalPublisher(t *testing.T) {
	testModelRevisionPreservesOriginalPublisher(t, memory.NewMemory(store.Config{}))
}

func TestCachedModelRevisionPreservesOriginalPublisher(t *testing.T) {
	testModelRevisionPreservesOriginalPublisher(t, store.NewCached(memory.NewMemory(store.Config{}), store.DefaultCacheConfig()))
}

func TestPostgresModelRevisionPreservesOriginalPublisher(t *testing.T) {
	testModelRevisionPreservesOriginalPublisher(t, testPostgresStore(t))
}
