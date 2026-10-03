package api

import (
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestPublishRevisionRetryAfter503PreservesStoredSource(t *testing.T) {
	for _, original := range []*store.HuggingFaceArtifact{
		nil,
		{RepoID: "original/weights", Revision: strings.Repeat("a", 40), PathPrefix: "mlx"},
	} {
		name := "r2-only"
		if original != nil {
			name = "pinned-hf"
		}
		t.Run(name, func(t *testing.T) {
			backing := &revisionCatalogFailureStore{Store: memory.NewMemory(store.Config{})}
			srv, st, manifest := revisionPublishFixture(t, backing)
			body := map[string]any{"version": manifest.Version}
			if original != nil {
				body["hugging_face_artifact"] = original
			}
			backing.fail.Store(true)
			if response := publishRevisionRequest(t, srv, manifest.ModelID, body); response.Code != http.StatusServiceUnavailable {
				t.Fatalf("expected committed publication with failed refresh: %d %s", response.Code, response.Body.String())
			}
			backing.fail.Store(false)
			for _, retry := range []map[string]any{
				{"version": manifest.Version},
				{"version": manifest.Version, "hugging_face_artifact": nil},
				{"version": manifest.Version, "hugging_face_artifact": &store.HuggingFaceArtifact{RepoID: "different/weights", Revision: strings.Repeat("b", 40), PathPrefix: "q4"}},
			} {
				if response := publishRevisionRequest(t, srv, manifest.ModelID, retry); response.Code != http.StatusOK {
					t.Fatalf("idempotent retry failed: %d %s", response.Code, response.Body.String())
				}
				record, err := st.GetModelRegistryRecord(manifest.ModelID)
				if err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(record.ActiveVersion.HuggingFaceArtifact, original) {
					t.Fatalf("retry replaced original locator: got %+v, want %+v", record.ActiveVersion.HuggingFaceArtifact, original)
				}
			}
			// An operator can later change or clear the mirror through full
			// registration. Replaying the original publication must not undo it.
			for _, editedSource := range []*store.HuggingFaceArtifact{
				{RepoID: "operator/new-mirror", Revision: strings.Repeat("c", 40)},
				nil,
			} {
				record, err := st.GetModelRegistryRecord(manifest.ModelID)
				if err != nil {
					t.Fatal(err)
				}
				record.ActiveVersion.HuggingFaceArtifact = editedSource
				if err := st.SetModelVersion(&record.ModelRegistryEntry, record.ActiveVersion, record.Files); err != nil {
					t.Fatal(err)
				}
				if response := publishRevisionRequest(t, srv, manifest.ModelID, body); response.Code != http.StatusOK {
					t.Fatalf("stale retry: %d %s", response.Code, response.Body.String())
				}
				after, err := st.GetModelRegistryRecord(manifest.ModelID)
				if err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(after.ActiveVersion.HuggingFaceArtifact, editedSource) {
					t.Fatalf("stale publisher undid operator mirror edit: %+v", after.ActiveVersion.HuggingFaceArtifact)
				}
			}
		})
	}
}
