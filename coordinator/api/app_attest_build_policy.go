package api

import (
	"encoding/hex"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func qualifiedAppAttestBuild(configured, hash string) bool {
	if !appAttestSHA256Hex(hash) {
		return false
	}
	for _, candidate := range strings.Split(configured, ",") {
		if strings.TrimSpace(candidate) == hash {
			return true
		}
	}
	return false
}

// CodeDirectory identifies the main executable. The separately loaded Metal
// library must ALSO remain approved under the current release generation.
// Its measurement is signed by the SE identity bound in the App Attest status.
func appAttestReleaseApproved(snapshot *releaseTrustPolicySnapshot, p *registry.Provider, status *protocol.AppAttestStatus) bool {
	if snapshot == nil || p == nil || status == nil {
		return false
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	ar := p.AttestationResult
	if !p.RuntimeVerified || !p.RuntimeManifestChecked || !p.MetallibVerified ||
		ar == nil || !ar.Valid || ar.PublicKey == "" || status.AttestationPublicKey != ar.PublicKey ||
		ar.EncryptionPublicKey != p.PublicKey || status.AppVersion != p.Version {
		return false
	}
	binary, err := normalizeSHA256Hex(status.BinaryHash, "app_attest.binary_hash")
	if err != nil {
		return false
	}
	if ar.BinaryHash != "" {
		registered, err := normalizeSHA256Hex(ar.BinaryHash, "registration.binary_hash")
		if err != nil || registered != binary {
			return false
		}
	}
	metallib, err := normalizeSHA256Hex(ar.MetallibHash, "signed.metallib_hash")
	if err != nil {
		return false
	}
	current, err := normalizeSHA256Hex(p.TemplateHashes["mlx_metallib"], "current.metallib_hash")
	if err != nil || current != metallib {
		return false
	}
	return releaseEvidenceStillApproved(snapshot, registry.ApplicationEvidence{Version: p.Version, Platform: "macos-arm64", Backend: p.Backend, BinaryHash: binary, MetallibHash: metallib})
}

// Explicit binary-SHA256:CodeDirectory-SHA256 pairs come from qualification of
// the same final signed artifact. No client field can add a mapping. The active
// release catalog and separate qualification allowlist must also approve it.
func qualifiedAppAttestMeasurement(configured, binaryHash string, metadata *appattest.Key) (known, matched bool) {
	measurement := metadata.CodeDirectorySHA256()
	if !appAttestSHA256Hex(binaryHash) || len(measurement) == 0 || strings.TrimSpace(configured) == "" {
		return false, false
	}
	expected := ""
	for _, pair := range strings.Split(configured, ",") {
		binary, code, ok := strings.Cut(strings.TrimSpace(pair), ":")
		if !ok || !appAttestSHA256Hex(binary) || !appAttestSHA256Hex(code) {
			return false, false
		}
		if binary == binaryHash {
			if expected != "" && expected != code {
				return false, false // Conflicting qualification cannot authorize.
			}
			expected = code
		}
	}
	return expected != "", expected != "" && expected == hex.EncodeToString(measurement)
}

func appAttestSHA256Hex(hash string) bool {
	if len(hash) != 64 || strings.ToLower(hash) != hash {
		return false
	}
	_, err := hex.DecodeString(hash)
	return err == nil
}
