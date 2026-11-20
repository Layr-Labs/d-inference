package registry

import (
	"encoding/base64"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestVerifiedPairAppAttestCleanupIdentityChangesOnlyProofSession(t *testing.T) {
	r, p, request, _ := appAttestPairFixture(t)
	_, m := pairTestActive(t, r, p, request)
	original := m.Members[0].Identity
	changed := original
	changed.ProofSessionID = "retry-proof"
	if !sameVerifiedPairCleanupIdentity(original, changed) {
		t.Fatal("same-connection proof renewal")
	}
	changes := map[string]func(*protocol.NativeMemberIdentity){
		"kind":       func(v *protocol.NativeMemberIdentity) { v.Kind = protocol.NativeIdentityLegacyMDA },
		"provider":   func(v *protocol.NativeMemberIdentity) { v.ProviderID = "replacement" },
		"account":    func(v *protocol.NativeMemberIdentity) { v.AccountID = "replacement" },
		"machine":    func(v *protocol.NativeMemberIdentity) { v.MachineID = "replacement" },
		"credential": func(v *protocol.NativeMemberIdentity) { v.CredentialID = "replacement" },
		"signer":     func(v *protocol.NativeMemberIdentity) { v.ControlPublicKey = m.Members[1].Identity.ControlPublicKey },
		"signer-representation": func(v *protocol.NativeMemberIdentity) {
			raw, _ := base64.StdEncoding.DecodeString(v.ControlPublicKey)
			v.ControlPublicKey = base64.StdEncoding.EncodeToString(raw[1:])
		},
		"endpoint":      func(v *protocol.NativeMemberIdentity) { v.ProcessPublicKey = m.Members[1].Identity.ProcessPublicKey },
		"binary":        func(v *protocol.NativeMemberIdentity) { v.BinarySHA256[0] ^= 1 },
		"metal":         func(v *protocol.NativeMemberIdentity) { v.MetallibSHA256[0] ^= 1 },
		"release":       func(v *protocol.NativeMemberIdentity) { v.ReleasePolicyGeneration++ },
		"serial":        func(v *protocol.NativeMemberIdentity) { v.DeviceSerial = "invented" },
		"missing-proof": func(v *protocol.NativeMemberIdentity) { v.ProofSessionID = "" },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			v := changed
			change(&v)
			if sameVerifiedPairCleanupIdentity(original, v) {
				t.Fatal("cleanup accepted another authority")
			}
		})
	}
}

func TestVerifiedPairAppAttestProofRenewalStillRequiresCurrentLeaseAndOriginalConnection(t *testing.T) {
	for _, kind := range []string{"expired", "revoked", "missing", "replacement", "representation"} {
		t.Run(kind, func(t *testing.T) {
			r, p, request, leases := appAttestPairFixture(t)
			h, m := pairTestActive(t, r, p, request)
			leases[0].ProofSessionID = "retry-proof"
			if !r.GrantAppAttestServingAuthorization(p[0], leases[0]) {
				t.Fatal("fresh proof fixture")
			}
			member := p[0]
			switch kind {
			case "expired":
				p[0].mu.Lock()
				p[0].appAttestAuthorization.ValidUntil = p[0].appAttestAuthorization.IssuedAt
				p[0].mu.Unlock()
			case "revoked":
				r.RevokeAppAttestCredential(leases[0].CredentialID)
			case "missing":
				r.ClearAppAttestServingAuthorization(p[0])
			case "replacement":
				member = pairTestMember(t, r, "replacement", "new-serial")
				pairTestAppAttest(t, r, member, leases[0].MachineID)
			case "representation":
				raw, _ := base64.StdEncoding.DecodeString(leases[0].VerifiedControlPublicKey)
				key := base64.StdEncoding.EncodeToString(raw[1:])
				p[0].mu.Lock()
				p[0].AttestationResult.PublicKey = key
				p[0].appAttestAuthorization.VerifiedControlPublicKey = key
				p[0].mu.Unlock()
			}
			if err := r.ObserveVerifiedPairOwnerReleased(h, member, m.TranscriptSHA256); err == nil {
				t.Fatal("renewal bypassed original release authority")
			}
			pairTestRequirePhase(t, r, h, VerifiedPairQuarantined)
		})
	}
}
