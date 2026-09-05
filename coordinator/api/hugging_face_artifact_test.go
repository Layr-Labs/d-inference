package api

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"strings"
	"testing"
)

func TestRegisterModelRejectsMutableHuggingFaceRevision(t *testing.T) {
	err := validateRegisterModelRequest(registerModelRequest{HuggingFaceArtifact: &store.HuggingFaceArtifact{RepoID: "EigenLabs/test", Revision: "main"}})
	if err == nil || !strings.Contains(err.Error(), "hugging_face_artifact.revision") {
		t.Fatalf("expected pinned-revision rejection, got %v", err)
	}
}

func TestLegacyCatalogOmitsHuggingFaceArtifact(t *testing.T) {
	model := catalogModelFromRegistryRecord(&store.ModelRegistryRecord{ActiveVersion: &store.ModelVersion{Version: "v1"}})
	if _, ok := model["hugging_face_artifact"]; ok {
		t.Fatal("legacy catalog must omit optional artifact")
	}
}
