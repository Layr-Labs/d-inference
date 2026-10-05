package store_test

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func testModelRevisionRetryPreservesStoredSource(t *testing.T, backing store.Store) {
	t.Helper()
	sources := []*store.HuggingFaceArtifact{
		nil,
		{RepoID: "original/weights", Revision: strings.Repeat("a", 40), PathPrefix: "mlx"},
	}
	replacement := &store.HuggingFaceArtifact{RepoID: "different/weights", Revision: strings.Repeat("b", 40), PathPrefix: "q4"}
	for _, original := range sources {
		name := "r2-only"
		if original != nil {
			name = "pinned-hf"
		}
		t.Run(name, func(t *testing.T) {
			cached := store.NewCached(backing, store.DefaultCacheConfig())
			entry, first, files := registryFixture(uniqueID("revision-source"), "v1")
			first.HuggingFaceArtifact = store.CloneHuggingFaceArtifact(original)
			if err := cached.SetModelVersion(entry, first, files); err != nil {
				t.Fatal(err)
			}
			if err := cached.PromoteModelVersion(entry.ID, first.Version); err != nil {
				t.Fatal(err)
			}
			assertSource := func(want *store.HuggingFaceArtifact) {
				t.Helper()
				for _, reader := range []store.Store{backing, cached} {
					record, err := reader.GetModelRegistryRecord(entry.ID)
					if err != nil {
						t.Fatal(err)
					}
					if !reflect.DeepEqual(record.ActiveVersion.HuggingFaceArtifact, want) {
						t.Fatalf("stored source changed: got %+v, want %+v", record.ActiveVersion.HuggingFaceArtifact, want)
					}
				}
			}
			assertSource(original) // Prime the cache before retrying publication.
			retrySource := func(incoming, want *store.HuggingFaceArtifact) {
				t.Helper()
				retry := *first
				retry.HuggingFaceArtifact = store.CloneHuggingFaceArtifact(incoming)
				if err := cached.SetExistingModelVersion(&retry, files); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(retry.HuggingFaceArtifact, want) {
					t.Fatalf("retry caller kept substituted source: got %+v, want %+v", retry.HuggingFaceArtifact, want)
				}
				if retry.HuggingFaceArtifact != nil {
					retry.HuggingFaceArtifact.RepoID = "mutated/caller"
				}
				assertSource(want)
			}
			for _, incoming := range []*store.HuggingFaceArtifact{nil, replacement} {
				retrySource(incoming, original)
			}
			// Full registration keeps its deliberate add/change/clear contract.
			// A stale revision replay must preserve the latest operator edit.
			for _, source := range []*store.HuggingFaceArtifact{replacement, nil, original} {
				edited := *first
				edited.HuggingFaceArtifact = store.CloneHuggingFaceArtifact(source)
				if err := cached.SetModelVersion(entry, &edited, files); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(edited.HuggingFaceArtifact, source) {
					t.Fatalf("registration did not return edited mirror: %+v", edited.HuggingFaceArtifact)
				}
				if edited.HuggingFaceArtifact != nil {
					edited.HuggingFaceArtifact.RepoID = "mutated/registration-caller"
				}
				assertSource(source)
				retrySource(original, source)
			}
			// Different immutable versions can independently choose another HF
			// source or R2-only delivery, while rollback keeps v1's locator.
			for i, source := range []*store.HuggingFaceArtifact{replacement, nil} {
				next := *first
				next.Version = fmt.Sprintf("v%d", i+2)
				next.R2Prefix = entry.ID + "/" + next.Version
				next.HuggingFaceArtifact = store.CloneHuggingFaceArtifact(source)
				if err := cached.SetExistingModelVersion(&next, files); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(next.HuggingFaceArtifact, source) {
					t.Fatalf("new revision lost its own source: %+v", next.HuggingFaceArtifact)
				}
				if err := cached.PromoteModelVersion(entry.ID, next.Version); err != nil {
					t.Fatal(err)
				}
				assertSource(source)
			}
			if err := cached.PromoteModelVersion(entry.ID, first.Version); err != nil {
				t.Fatal(err)
			}
			assertSource(original)
		})
	}
}

func TestMemoryModelRevisionRetryPreservesStoredSource(t *testing.T) {
	testModelRevisionRetryPreservesStoredSource(t, memory.NewMemory(store.Config{}))
}

func TestPostgresModelRevisionRetryPreservesStoredSource(t *testing.T) {
	testModelRevisionRetryPreservesStoredSource(t, testPostgresStore(t))
}
