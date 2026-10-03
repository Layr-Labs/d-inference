package releases

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestPolicyViewsRemainDetachedAcrossPublication(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	s := releaseOwnerFixture(registry.New(quietLogger()), st, quietLogger())
	row := testRelease("1.0.0", strings.Repeat("a", 64))
	if err := st.SetRelease(row); err != nil {
		t.Fatal(err)
	}
	if err := s.SyncBinaryHashes(); err != nil {
		t.Fatal(err)
	}
	before := s.Policy()
	if !before.ContainsQualifiedRelease(*row) {
		t.Fatal("published release absent")
	}
	before.Required = false
	if !s.Policy().Required {
		t.Fatal("view mutation changed published policy")
	}
	configured, hashes := s.BinaryHashPolicySnapshot()
	delete(hashes, row.BinaryHash)
	_, currentHashes := s.BinaryHashPolicySnapshot()
	if !configured || !currentHashes[row.BinaryHash] {
		t.Fatal("hash snapshot was not detached")
	}
	if err := st.DeleteRelease(row.Version, row.Platform); err != nil {
		t.Fatal(err)
	}
	if err := s.SyncBinaryHashes(); err != nil {
		t.Fatal(err)
	}
	if !before.ContainsQualifiedRelease(*row) || s.Policy().ContainsQualifiedRelease(*row) {
		t.Fatal("publication changed a captured view or retained a withdrawn release")
	}
}

func TestRuntimeManifestInputAndViewsAreDetached(t *testing.T) {
	s := releaseOwnerFixture(registry.New(quietLogger()), memory.NewMemory(store.Config{}), quietLogger())
	hash := strings.Repeat("a", 64)
	m := NewRuntimeManifest()
	m.AddTemplateHash("mlx_metallib", hash)
	s.SetRuntimeManifest(m)
	delete(m.TemplateHashes, "mlx_metallib")
	view := s.RuntimeManifest()
	delete(view.TemplateHashes, "mlx_metallib")
	if !s.RuntimeApprovesMetallib(map[string]string{"mlx_metallib": hash}) {
		t.Fatal("caller mutation changed live runtime policy")
	}
	s.SetRuntimeManifest(nil)
	if s.RuntimeManifest() != nil || s.RuntimeConfigured() {
		t.Fatal("nil withdrawal lost")
	}
}
