package store

import (
	"fmt"
	"regexp"
	"strings"
)

// HuggingFaceArtifact locates the exact published bytes, independently of the
// upstream hugging_face_id used for model metadata. Paths mirror the manifest.
type HuggingFaceArtifact struct {
	RepoID     string `json:"repo_id"`
	Revision   string `json:"revision"`
	PathPrefix string `json:"path_prefix,omitempty"`
}

var hfRepositoryComponent = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9._-]*$`)
var hfCommitRevision = regexp.MustCompile(`^[0-9a-f]{40}$`)

func (a *HuggingFaceArtifact) Validate() error {
	if a == nil {
		return nil
	}
	parts := strings.Split(a.RepoID, "/")
	if len(parts) != 2 || len(a.RepoID) > 192 {
		return fmt.Errorf("hugging_face_artifact.repo_id must be owner/repository")
	}
	for _, part := range parts {
		if !hfRepositoryComponent.MatchString(part) || strings.Contains(part, "..") {
			return fmt.Errorf("hugging_face_artifact.repo_id contains invalid characters")
		}
	}
	if !hfCommitRevision.MatchString(a.Revision) {
		return fmt.Errorf("hugging_face_artifact.revision must be a full lowercase 40-character commit SHA")
	}
	if a.PathPrefix != "" {
		if len(a.PathPrefix) > 1024 {
			return fmt.Errorf("hugging_face_artifact.path_prefix is too long")
		}
		for _, part := range strings.Split(a.PathPrefix, "/") {
			if !hfRepositoryComponent.MatchString(part) || strings.Contains(part, "..") {
				return fmt.Errorf("hugging_face_artifact.path_prefix must be a relative path of repository components")
			}
		}
	}
	return nil
}

func cloneHuggingFaceArtifact(a *HuggingFaceArtifact) *HuggingFaceArtifact {
	if a == nil {
		return nil
	}
	cp := *a
	return &cp
}
