package releases

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestRemoteReleaseRefreshConvergesWithoutGenerationChurn(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	logger := quietLogger()
	s := releaseOwnerFixture(registry.New(logger), st, logger)
	release := store.Release{Version: "1.0.0", Platform: "macos-arm64", Backend: "mlx-swift",
		BinaryHash: strings.Repeat("a", 64), BundleHash: strings.Repeat("b", 64),
		MetallibHash: strings.Repeat("c", 64), URL: "https://example.invalid/bundle.tar.gz"}
	if err := st.SetRelease(&release); err != nil {
		t.Fatal(err)
	}
	if err := s.RefreshAppAttestReleaseCatalog(); err != nil {
		t.Fatal(err)
	}
	first := s.Policy()
	if !first.ContainsQualifiedRelease(release) {
		t.Fatal("remote publication not loaded")
	}
	for range 3 {
		if err := s.RefreshAppAttestReleaseCatalog(); err != nil {
			t.Fatal(err)
		}
	}
	if s.Policy().Generation != first.Generation {
		t.Fatal("unchanged catalog invalidated live leases")
	}
	if err := st.DeleteRelease(release.Version, release.Platform); err != nil {
		t.Fatal(err)
	}
	if err := s.RefreshAppAttestReleaseCatalog(); err != nil {
		t.Fatal(err)
	}
	if s.Policy().Known() {
		t.Fatal("remote release withdrawal did not fence")
	}
}
