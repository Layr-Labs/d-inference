package store

import (
	"testing"
	"time"
)

func TestReleaseStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testReleaseStoreContract(t, st)
		})
	}
}

func testReleaseStoreContract(t *testing.T, st Store) {
	t.Helper()

	platform := uniqueID("macos-arm64")
	created := time.Date(2026, time.August, 22, 12, 0, 0, 0, time.UTC)
	if releases := st.ListReleases(); len(releases) != 0 {
		t.Fatalf("initial releases = %d, want 0", len(releases))
	}
	if latest := st.GetLatestRelease(platform); latest != nil {
		t.Fatalf("initial latest = %+v, want nil", latest)
	}

	r1 := &Release{
		Version:    "0.2.0",
		Platform:   platform,
		BinaryHash: "aaa111",
		BundleHash: "bbb222",
		URL:        "https://r2.example.com/releases/v0.2.0/bundle.tar.gz",
		CreatedAt:  created,
	}
	r2 := &Release{
		Version:      "0.2.1",
		Platform:     platform,
		Backend:      "mlx-swift",
		BinaryHash:   "ccc333",
		BundleHash:   "ddd444",
		MetallibHash: "eee555",
		URL:          "https://r2.example.com/releases/v0.2.1/bundle.tar.gz",
		CreatedAt:    created.Add(time.Minute),
	}
	if err := st.SetRelease(r1); err != nil {
		t.Fatalf("set r1: %v", err)
	}
	if err := st.SetRelease(r2); err != nil {
		t.Fatalf("set r2: %v", err)
	}

	releases := st.ListReleases()
	if len(releases) != 2 {
		t.Fatalf("releases = %d, want 2", len(releases))
	}
	if releases[0].CreatedAt.Before(releases[1].CreatedAt) {
		t.Fatalf("releases are not ordered by created_at descending: %+v", releases)
	}
	versions := map[string]bool{releases[0].Version: true, releases[1].Version: true}
	if !versions[r1.Version] || !versions[r2.Version] {
		t.Fatalf("release list lost a version: %+v", releases)
	}
	latest := st.GetLatestRelease(platform)
	if latest == nil ||
		latest.Version != r2.Version ||
		latest.BinaryHash != r2.BinaryHash ||
		latest.Backend != r2.Backend ||
		latest.MetallibHash != r2.MetallibHash {
		t.Fatalf("latest mismatch: %+v", latest)
	}
	if latest := st.GetLatestRelease(uniqueID("unknown-platform")); latest != nil {
		t.Fatalf("unknown platform latest = %+v, want nil", latest)
	}

	if err := st.DeleteRelease(r2.Version, platform); err != nil {
		t.Fatalf("delete r2: %v", err)
	}
	if latest := st.GetLatestRelease(platform); latest == nil || latest.Version != r1.Version {
		t.Fatalf("latest after delete = %+v, want %s", latest, r1.Version)
	}
	if err := st.DeleteRelease("9.9.9", platform); err == nil {
		t.Fatal("delete missing release succeeded")
	}
	if err := st.SetRelease(&Release{Platform: platform}); err == nil {
		t.Fatal("set empty version succeeded")
	}

	semverPlatform := uniqueID("semver-platform")
	if err := st.SetRelease(&Release{
		Version:    "0.3.9",
		Platform:   semverPlatform,
		BinaryHash: "higher-semver",
		BundleHash: "bundle-higher-semver",
		URL:        "https://r2.example.com/releases/v0.3.9/bundle.tar.gz",
		CreatedAt:  created,
	}); err != nil {
		t.Fatalf("set 0.3.9: %v", err)
	}
	if err := st.SetRelease(&Release{
		Version:    "0.3.8",
		Platform:   semverPlatform,
		BinaryHash: "newer-timestamp",
		BundleHash: "bundle-newer-timestamp",
		URL:        "https://r2.example.com/releases/v0.3.8/bundle.tar.gz",
		CreatedAt:  created.Add(time.Hour),
	}); err != nil {
		t.Fatalf("set 0.3.8: %v", err)
	}
	if latest := st.GetLatestRelease(semverPlatform); latest == nil || latest.Version != "0.3.9" {
		t.Fatalf("semver latest = %+v, want 0.3.9", latest)
	}
}
