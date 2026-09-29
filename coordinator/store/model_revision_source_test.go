package store

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func testModelRevisionRetryPreservesStoredSource(t *testing.T, backing Store) {
	t.Helper()
	sources := []*HuggingFaceArtifact{
		nil,
		{RepoID: "original/weights", Revision: strings.Repeat("a", 40), PathPrefix: "mlx"},
	}
	replacement := &HuggingFaceArtifact{RepoID: "different/weights", Revision: strings.Repeat("b", 40), PathPrefix: "q4"}
	for _, original := range sources {
		name := "r2-only"
		if original != nil {
			name = "pinned-hf"
		}
		t.Run(name, func(t *testing.T) {
			cached := NewCached(backing, DefaultCacheConfig())
			entry, first, files := registryFixture(uniqueID("revision-source"), "v1")
			first.HuggingFaceArtifact = cloneHuggingFaceArtifact(original)
			if err := cached.SetModelVersion(entry, first, files); err != nil {
				t.Fatal(err)
			}
			if err := cached.PromoteModelVersion(entry.ID, first.Version); err != nil {
				t.Fatal(err)
			}
			assertSource := func(want *HuggingFaceArtifact) {
				t.Helper()
				for _, reader := range []Store{backing, cached} {
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
			retrySource := func(incoming, want *HuggingFaceArtifact) {
				t.Helper()
				retry := *first
				retry.HuggingFaceArtifact = cloneHuggingFaceArtifact(incoming)
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
			for _, incoming := range []*HuggingFaceArtifact{nil, replacement} {
				retrySource(incoming, original)
			}
			// Full registration keeps its deliberate add/change/clear contract.
			// A stale revision replay must preserve the latest operator edit.
			for _, source := range []*HuggingFaceArtifact{replacement, nil, original} {
				edited := *first
				edited.HuggingFaceArtifact = cloneHuggingFaceArtifact(source)
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
			for i, source := range []*HuggingFaceArtifact{replacement, nil} {
				next := *first
				next.Version = fmt.Sprintf("v%d", i+2)
				next.R2Prefix = entry.ID + "/" + next.Version
				next.HuggingFaceArtifact = cloneHuggingFaceArtifact(source)
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
	testModelRevisionRetryPreservesStoredSource(t, NewMemory(Config{}))
}

func TestPostgresModelRevisionRetryPreservesStoredSource(t *testing.T) {
	testModelRevisionRetryPreservesStoredSource(t, testPostgresStore(t))
}
