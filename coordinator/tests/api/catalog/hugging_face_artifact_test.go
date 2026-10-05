package catalog_test

import (
	"strings"
	"testing"

	registration "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/registration"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRegisterModelRejectsMutableHuggingFaceRevision(t *testing.T) {
	err := registration.ValidateRegisterModelRequest(registration.RegisterModelRequest{HuggingFaceArtifact: &store.HuggingFaceArtifact{RepoID: "EigenLabs/test", Revision: "main"}})
	if err == nil || !strings.Contains(err.Error(), "hugging_face_artifact.revision") {
		t.Fatalf("expected pinned-revision rejection, got %v", err)
	}
}

func TestLegacyCatalogOmitsHuggingFaceArtifact(t *testing.T) {
	model := registration.CatalogModelFromRegistryRecord(&store.ModelRegistryRecord{ActiveVersion: &store.ModelVersion{Version: "v1"}})
	if _, ok := model["hugging_face_artifact"]; ok {
		t.Fatal("legacy catalog must omit optional artifact")
	}
}
