package store

import "time"

// ReleaseStore covers versioned provider binary releases.
type ReleaseStore interface {
	// SetRelease adds or updates a release in the store.
	SetRelease(release *Release) error

	// ListReleases returns all releases, ordered by created_at descending.
	ListReleases() []Release

	// GetLatestRelease returns the latest active release for a platform.
	GetLatestRelease(platform string) *Release

	// DeleteRelease deactivates a release by version and platform.
	DeleteRelease(version, platform string) error
}

// Release represents a versioned provider binary release.
// The GitHub Action registers new releases via POST /v1/releases (scoped key).
// Admins manage releases via /v1/admin/releases (Privy auth).
type Release struct {
	Version        string    `json:"version"`                   // semver, e.g. "0.5.0"
	Platform       string    `json:"platform"`                  // "macos-arm64"
	Backend        string    `json:"backend,omitempty"`         // "mlx-swift" (post-cutover) or "vllm-mlx" (legacy)
	BinaryHash     string    `json:"binary_hash"`               // SHA-256 of darkbloom binary (attestation verification)
	BundleHash     string    `json:"bundle_hash"`               // SHA-256 of the bundle tarball (install.sh download verification)
	MetallibHash   string    `json:"metallib_hash,omitempty"`   // SHA-256 of mlx.metallib (Swift backend GPU kernel set)
	PythonHash     string    `json:"python_hash,omitempty"`     // legacy: SHA-256 of bundled Python binary (vllm-mlx backend only)
	RuntimeHash    string    `json:"runtime_hash,omitempty"`    // legacy: SHA-256 of vllm-mlx package (vllm-mlx backend only)
	TemplateHashes string    `json:"template_hashes,omitempty"` // comma-separated name=hash pairs
	URL            string    `json:"url"`                       // R2 download URL for the bundle tarball
	Changelog      string    `json:"changelog"`                 // human-readable changes in this version
	Active         bool      `json:"active"`                    // whether this version is accepted by the coordinator
	CreatedAt      time.Time `json:"created_at"`
}
