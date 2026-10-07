package api_test

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func testRelease(version, hash string) *store.Release {
	return &store.Release{
		Version: version, Platform: "macos-arm64", Backend: registry.BackendMLXSwift,
		BinaryHash: hash, BundleHash: strings.Repeat("f", 64),
		MetallibHash: trHashC,
		URL:          "https://releases.example/" + version + ".tar.gz",
	}
}
