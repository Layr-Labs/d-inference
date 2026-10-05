package store

import "time"

// Release represents a versioned provider binary release.
// The GitHub Action registers new releases via POST /v1/releases (scoped key).
// Admins manage releases via /v1/admin/releases (Privy auth).
type Release struct {
	Version        string    `json:"version"`                   // semver, e.g. "0.5.0"
	Platform       string    `json:"platform"`                  // "macos-arm64"
	Backend        string    `json:"backend,omitempty"`         // "mlx-swift"; empty on rows registered before the column existed
	BinaryHash     string    `json:"binary_hash"`               // SHA-256 of darkbloom binary (attestation verification)
	BundleHash     string    `json:"bundle_hash"`               // SHA-256 of the bundle tarball (install.sh download verification)
	MetallibHash   string    `json:"metallib_hash,omitempty"`   // SHA-256 of mlx.metallib (Swift backend GPU kernel set)
	TemplateHashes string    `json:"template_hashes,omitempty"` // comma-separated name=hash pairs
	URL            string    `json:"url"`                       // R2 download URL for the bundle tarball
	Changelog      string    `json:"changelog"`                 // human-readable changes in this version
	Active         bool      `json:"active"`                    // whether this version is accepted by the coordinator
	CreatedAt      time.Time `json:"created_at"`
}
