package api

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestValidateReleaseMetadataRequiresCanonicalSemVer(t *testing.T) {
	t.Parallel()
	server := &Server{}
	valid := []string{
		"0.0.0",
		"1.2.3-alpha.1+build.01",
		"184467440737095516160.0.0",
	}
	invalid := []string{
		"",
		"v1.0.0",
		"1.0",
		"01.0.0",
		"1.0.0-alpha.01",
		"1.0.0-alpha..1",
		"1.0.0+",
	}

	for _, version := range valid {
		version := version
		t.Run("valid/"+version, func(t *testing.T) {
			t.Parallel()
			release := validReleaseMetadata(version)
			if err := server.validateReleaseMetadata(&release); err != nil {
				t.Fatalf("validateReleaseMetadata(%q): %v", version, err)
			}
		})
	}
	for _, version := range invalid {
		version := version
		t.Run("invalid/"+version, func(t *testing.T) {
			t.Parallel()
			release := validReleaseMetadata(version)
			if err := server.validateReleaseMetadata(&release); err == nil {
				t.Fatalf("validateReleaseMetadata accepted %q", version)
			}
		})
	}
}

func TestServerSemVerComparisonIsStrict(t *testing.T) {
	t.Parallel()
	if !semverGreater("1.0.0", "1.0.0-rc.1") {
		t.Fatal("stable release must sort after its prerelease")
	}
	if !semverGreater(
		"184467440737095516161.0.0",
		"184467440737095516160.0.0",
	) {
		t.Fatal("comparison truncated an unbounded numeric identifier")
	}
	if semverGreater("1.0.0-alpha.01", "1.0.0-alpha.1") {
		t.Fatal("invalid prerelease participated in release ordering")
	}
	if !semverLess("not-a-version", "1.0.0") {
		t.Fatal("invalid provider version must fail a valid minimum floor")
	}
}

func validReleaseMetadata(version string) store.Release {
	return store.Release{
		Version:    version,
		Platform:   "macos-arm64",
		BinaryHash: strings.Repeat("a", 64),
		BundleHash: strings.Repeat("b", 64),
		URL:        "https://example.invalid/release.tar.gz",
	}
}
