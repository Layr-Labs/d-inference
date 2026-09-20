package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

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
