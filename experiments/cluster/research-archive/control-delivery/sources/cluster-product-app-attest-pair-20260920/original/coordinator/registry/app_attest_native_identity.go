package registry

import (
	"encoding/hex"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Empty proof preserves older ordinary-serving callers. Native identity below
// requires all three fields from the real V3 verdict and release callback.
// Caller holds p.mu. This binding check is not a replacement for that verifier.
type AppAttestRuntimeBinding struct{ ControlPublicKey, BinaryHash, MetallibHash string }

func appAttestControlBindingMatchesLocked(p *Provider, lease AppAttestServingAuthorization) bool {
	if lease.VerifiedControlPublicKey == "" && lease.VerifiedBinaryHash == "" && lease.VerifiedMetallibHash == "" {
		return true
	}
	a := p.AttestationResult
	if a == nil || !a.Valid || lease.VerifiedControlPublicKey == "" || lease.VerifiedControlPublicKey != a.PublicKey || a.EncryptionPublicKey != p.PublicKey {
		return false
	}
	if _, ok := nativeIdentityHash(lease.VerifiedBinaryHash); !ok {
		return false
	}
	if a.BinaryHash != "" && strings.ToLower(a.BinaryHash) != lease.VerifiedBinaryHash {
		return false
	}
	if lease.VerifiedMetallibHash != "" {
		if _, ok := nativeIdentityHash(lease.VerifiedMetallibHash); !ok {
			return false
		}
		if !p.RuntimeVerified || !p.RuntimeManifestChecked || !p.MetallibVerified || strings.ToLower(a.MetallibHash) != lease.VerifiedMetallibHash || strings.ToLower(p.TemplateHashes["mlx_metallib"]) != lease.VerifiedMetallibHash {
			return false
		}
	}
	return true
}

func nativeIdentityHash(s string) ([32]byte, bool) {
	var out [32]byte
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != 32 || strings.ToLower(s) != s {
		return out, false
	}
	copy(out[:], b)
	return out, out != [32]byte{}
}

// Caller holds r.mu and p.mu. This is an identity projection ONLY. Pair route,
// idle/capacity, mutual consent, pending hold, two prepared ACKs and commit all
// remain separate. This slice deliberately does not wire a new admission path.
// The returned value excludes refreshing lease deadlines; current authority
// must be checked again for every use, and expiry must retire an active owner.
func (r *Registry) appAttestNativeIdentityLocked(p *Provider, now time.Time) (protocol.NativeMemberIdentity, bool) {
	var out protocol.NativeMemberIdentity
	if p == nil || r.providers[p.ID] != p || p.registry != r || !r.providerAppAttestServingAuthorizedLocked(p, now) || !p.RuntimeManifestChecked || !p.MetallibVerified {
		return out, false
	}
	lease, a := p.appAttestAuthorization, p.AttestationResult
	if lease.VerifiedControlPublicKey == "" || lease.VerifiedBinaryHash == "" || lease.VerifiedMetallibHash == "" || a == nil || !a.Valid || lease.PolicyGeneration == 0 || lease.PolicyGeneration != r.releasePolicyGeneration {
		return out, false
	}
	binary, binaryOK := nativeIdentityHash(lease.VerifiedBinaryHash)
	metal, metalOK := nativeIdentityHash(lease.VerifiedMetallibHash)
	if !binaryOK || !metalOK || strings.ToLower(p.TemplateHashes["mlx_metallib"]) != strings.ToLower(a.MetallibHash) {
		return out, false
	}
	if _, _, _, err := attestedRuntimeCapabilitiesLocked(p); err != nil {
		return out, false
	}
	out = protocol.NativeMemberIdentity{
		Kind: protocol.NativeIdentityAppAttest, ProviderID: p.ID,
		ControlPublicKey: lease.VerifiedControlPublicKey, ProcessPublicKey: lease.Endpoint,
		BinarySHA256: binary, MetallibSHA256: metal, ReleasePolicyGeneration: lease.PolicyGeneration,
		AccountID: lease.AccountID, MachineID: lease.MachineID,
		CredentialID: lease.CredentialID, ProofSessionID: lease.ProofSessionID,
	}
	if out.Validate() != nil {
		return protocol.NativeMemberIdentity{}, false
	}
	return out, true
}
