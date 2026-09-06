package store

import (
	"testing"
	"time"
)

func TestReleases(t *testing.T) {
	s := NewMemory(Config{})
	hasApp := true
	hasFanHelper := true
	hasPagedKernel := false

	// Empty initially.
	releases := s.ListReleases()
	if len(releases) != 0 {
		t.Fatalf("expected 0 releases, got %d", len(releases))
	}
	if releasesWithError, err := s.ListReleasesWithError(); err != nil || len(releasesWithError) != 0 {
		t.Fatalf("empty ListReleasesWithError = %+v, err=%v", releasesWithError, err)
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
		Version:        "0.2.1",
		Platform:       "macos-arm64",
		Backend:        "mlx-swift",
		BinaryHash:     "ccc333",
		BundleHash:     "ddd444",
		MetallibHash:   "eee555",
		HasApp:         &hasApp,
		HasFanHelper:   &hasFanHelper,
		HasPagedKernel: &hasPagedKernel,
		URL:            "https://r2.example.com/releases/v0.2.1/bundle.tar.gz",
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
	releasesWithError, err := s.ListReleasesWithError()
	if err != nil || len(releasesWithError) != 2 {
		t.Fatalf("ListReleasesWithError = %+v, err=%v", releasesWithError, err)
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
	if latest.HasApp == nil || !*latest.HasApp {
		t.Errorf("expected has_app true, got %v", latest.HasApp)
	}
	if latest.HasFanHelper == nil || !*latest.HasFanHelper {
		t.Errorf("expected has_fan_helper true, got %v", latest.HasFanHelper)
	}
	if latest.HasPagedKernel == nil || *latest.HasPagedKernel {
		t.Errorf("expected has_paged_kernel false, got %v", latest.HasPagedKernel)
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

func TestReleaseArtifactCapabilitiesRoundTrip(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			hasApp := true
			hasFanHelper := false
			hasPagedKernel := true
			release := &Release{
				Version:        "1.2.3",
				Platform:       "macos-arm64",
				BinaryHash:     "binary",
				BundleHash:     "bundle",
				HasApp:         &hasApp,
				HasFanHelper:   &hasFanHelper,
				HasPagedKernel: &hasPagedKernel,
				URL:            "https://example.test/release.tar.gz",
			}
			if err := backend.SetRelease(release); err != nil {
				t.Fatalf("SetRelease: %v", err)
			}

			latest := backend.GetLatestRelease("macos-arm64")
			if latest == nil {
				t.Fatal("GetLatestRelease returned nil")
			}
			assertReleaseCapability(t, "has_app", latest.HasApp, true)
			assertReleaseCapability(
				t,
				"has_fan_helper",
				latest.HasFanHelper,
				false,
			)
			assertReleaseCapability(
				t,
				"has_paged_kernel",
				latest.HasPagedKernel,
				true,
			)

			listed := backend.ListReleases()
			if len(listed) != 1 {
				t.Fatalf("ListReleases returned %d releases, want 1", len(listed))
			}
			assertReleaseCapability(t, "listed has_app", listed[0].HasApp, true)
			assertReleaseCapability(
				t,
				"listed has_fan_helper",
				listed[0].HasFanHelper,
				false,
			)
			assertReleaseCapability(
				t,
				"listed has_paged_kernel",
				listed[0].HasPagedKernel,
				true,
			)
		})
	}
}

func TestLegacyReleaseArtifactCapabilitiesRemainUnknown(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			platform := uniqueID("legacy-capabilities")
			release := &Release{
				Version:    "1.2.3",
				Platform:   platform,
				BinaryHash: "binary",
				BundleHash: "bundle",
				URL:        "https://example.test/release.tar.gz",
			}
			if err := backend.SetRelease(release); err != nil {
				t.Fatalf("SetRelease: %v", err)
			}

			latest := backend.GetLatestRelease(platform)
			if latest == nil {
				t.Fatal("GetLatestRelease returned nil")
			}
			assertUnknownReleaseCapabilities(t, "latest", latest)

			var listed *Release
			releases := backend.ListReleases()
			for index := range releases {
				candidate := releases[index]
				if candidate.Platform == platform && candidate.Version == release.Version {
					listed = &candidate
					break
				}
			}
			if listed == nil {
				t.Fatal("ListReleases omitted legacy release")
			}
			assertUnknownReleaseCapabilities(t, "listed", listed)
		})
	}
}

func assertUnknownReleaseCapabilities(t *testing.T, label string, release *Release) {
	t.Helper()
	if release.HasApp != nil ||
		release.HasFanHelper != nil ||
		release.HasPagedKernel != nil {
		t.Fatalf("%s release capabilities = %+v, want nil", label, release)
	}
}

func assertReleaseCapability(
	t *testing.T,
	label string,
	actual *bool,
	expected bool,
) {
	t.Helper()
	if actual == nil || *actual != expected {
		t.Fatalf("%s = %v, want %t", label, actual, expected)
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

func TestPostgresListReleasesWithErrorSurfacesQueryFailure(t *testing.T) {
	s := testPostgresStore(t)
	s.Close()
	if releases, err := s.ListReleasesWithError(); err == nil || releases != nil {
		t.Fatalf("closed-pool ListReleasesWithError = %+v, err=%v; want nil result and non-nil error", releases, err)
	}
}

func TestSetReleaseRejectsNoncanonicalSemVer(t *testing.T) {
	t.Parallel()
	invalid := []string{
		"",
		"v1.0.0",
		"1.0",
		"01.0.0",
		"1.0.0-alpha.01",
		"1.0.0+",
	}
	for _, version := range invalid {
		version := version
		t.Run(version, func(t *testing.T) {
			t.Parallel()
			s := NewMemory(Config{})
			if err := s.SetRelease(&Release{
				Version:  version,
				Platform: "macos-arm64",
			}); err == nil {
				t.Fatalf("SetRelease accepted invalid version %q", version)
			}
		})
	}
}

func TestGetLatestReleaseUsesSemVerPrereleasePrecedence(t *testing.T) {
	t.Parallel()
	s := NewMemory(Config{})
	versions := []string{
		"1.0.0",
		"1.0.0-rc.1",
		"1.0.0-beta.11",
		"1.0.0+older-build",
		"184467440737095516160.0.0",
	}
	for index, version := range versions {
		if err := s.SetRelease(&Release{
			Version:   version,
			Platform:  "macos-arm64",
			CreatedAt: time.Unix(int64(index), 0),
		}); err != nil {
			t.Fatalf("SetRelease(%q): %v", version, err)
		}
	}

	latest := s.GetLatestRelease("macos-arm64")
	if latest == nil {
		t.Fatal("expected latest release")
	}
	if latest.Version != "184467440737095516160.0.0" {
		t.Fatalf("latest version = %q", latest.Version)
	}
}

func TestGetLatestReleaseBreaksEqualPrecedenceByTimestamp(t *testing.T) {
	t.Parallel()
	s := NewMemory(Config{})
	older := time.Unix(1, 0)
	newer := time.Unix(2, 0)
	for _, release := range []*Release{
		{
			Version:   "1.0.0+build.1",
			Platform:  "macos-arm64",
			CreatedAt: older,
		},
		{
			Version:   "1.0.0+build.2",
			Platform:  "macos-arm64",
			CreatedAt: newer,
		},
	} {
		if err := s.SetRelease(release); err != nil {
			t.Fatalf("SetRelease(%q): %v", release.Version, err)
		}
	}

	latest := s.GetLatestRelease("macos-arm64")
	if latest == nil || latest.Version != "1.0.0+build.2" {
		t.Fatalf("latest = %#v", latest)
	}
}
