package store

import (
	"testing"
	"time"
)

func TestReleases(t *testing.T) {
	s := NewMemory(Config{})

	// Empty initially.
	releases := s.ListReleases()
	if len(releases) != 0 {
		t.Fatalf("expected 0 releases, got %d", len(releases))
	}
	if r := s.GetLatestRelease("macos-arm64"); r != nil {
		t.Fatal("expected nil latest release")
	}

	// Add releases.
	r1 := &Release{
		Version:    "0.2.0",
		Platform:   "macos-arm64",
		BinaryHash: "aaa111",
		BundleHash: "bbb222",
		URL:        "https://r2.example.com/releases/v0.2.0/bundle.tar.gz",
	}
	r2 := &Release{
		Version:      "0.2.1",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   "ccc333",
		BundleHash:   "ddd444",
		MetallibHash: "eee555",
		URL:          "https://r2.example.com/releases/v0.2.1/bundle.tar.gz",
	}
	if err := s.SetRelease(r1); err != nil {
		t.Fatalf("SetRelease r1: %v", err)
	}
	// Small delay so r2 has a later timestamp.
	time.Sleep(time.Millisecond)
	if err := s.SetRelease(r2); err != nil {
		t.Fatalf("SetRelease r2: %v", err)
	}

	releases = s.ListReleases()
	if len(releases) != 2 {
		t.Fatalf("expected 2 releases, got %d", len(releases))
	}

	// Latest should be r2.
	latest := s.GetLatestRelease("macos-arm64")
	if latest == nil {
		t.Fatal("expected non-nil latest release")
	}
	if latest.Version != "0.2.1" {
		t.Errorf("expected latest version 0.2.1, got %s", latest.Version)
	}
	if latest.BinaryHash != "ccc333" {
		t.Errorf("expected binary_hash ccc333, got %s", latest.BinaryHash)
	}
	if latest.Backend != "mlx-swift" {
		t.Errorf("expected backend mlx-swift, got %s", latest.Backend)
	}
	if latest.MetallibHash != "eee555" {
		t.Errorf("expected metallib_hash eee555, got %s", latest.MetallibHash)
	}

	// Unknown platform returns nil.
	if r := s.GetLatestRelease("linux-amd64"); r != nil {
		t.Error("expected nil for unknown platform")
	}

	// Deactivate r2.
	if err := s.DeleteRelease("0.2.1", "macos-arm64"); err != nil {
		t.Fatalf("DeleteRelease: %v", err)
	}

	// Latest should now be r1.
	latest = s.GetLatestRelease("macos-arm64")
	if latest == nil {
		t.Fatal("expected non-nil latest after deactivation")
	}
	if latest.Version != "0.2.0" {
		t.Errorf("expected latest version 0.2.0 after deactivation, got %s", latest.Version)
	}

	// Deactivate nonexistent.
	if err := s.DeleteRelease("9.9.9", "macos-arm64"); err == nil {
		t.Error("expected error for nonexistent release")
	}

	// Validation: empty version.
	if err := s.SetRelease(&Release{Platform: "macos-arm64"}); err == nil {
		t.Error("expected error for empty version")
	}
}

func TestGetLatestReleasePrefersHigherSemverOverNewerTimestamp(t *testing.T) {
	s := NewMemory(Config{})

	if err := s.SetRelease(&Release{
		Version:    "0.3.9",
		Platform:   "macos-arm64",
		BinaryHash: "higher-semver",
		BundleHash: "bundle-higher-semver",
		URL:        "https://r2.example.com/releases/v0.3.9/bundle.tar.gz",
		CreatedAt:  time.Now().Add(-time.Hour),
	}); err != nil {
		t.Fatalf("SetRelease 0.3.9: %v", err)
	}

	if err := s.SetRelease(&Release{
		Version:    "0.3.8",
		Platform:   "macos-arm64",
		BinaryHash: "newer-timestamp",
		BundleHash: "bundle-newer-timestamp",
		URL:        "https://r2.example.com/releases/v0.3.8/bundle.tar.gz",
		CreatedAt:  time.Now(),
	}); err != nil {
		t.Fatalf("SetRelease 0.3.8: %v", err)
	}

	latest := s.GetLatestRelease("macos-arm64")
	if latest == nil {
		t.Fatal("expected non-nil latest release")
	}
	if latest.Version != "0.3.9" {
		t.Fatalf("latest version = %q, want %q", latest.Version, "0.3.9")
	}
}
