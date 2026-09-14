package releasepolicy

import (
	"strings"
	"testing"
)

func TestRuntimeManifestApprovalRequiresExplicitMetallibEntry(t *testing.T) {
	hash := strings.Repeat("a", 64)
	if RuntimeManifestApprovesMetallib(
		&RuntimeManifest{TemplateHashes: map[string]map[string]bool{}},
		map[string]string{"mlx_metallib": hash},
	) {
		t.Fatal("missing approved mlx_metallib entry was accepted")
	}
	if !RuntimeManifestApprovesMetallib(
		&RuntimeManifest{TemplateHashes: map[string]map[string]bool{"mlx_metallib": {hash: true}}},
		map[string]string{"mlx_metallib": hash},
	) {
		t.Fatal("explicit matching mlx_metallib entry was rejected")
	}
}
