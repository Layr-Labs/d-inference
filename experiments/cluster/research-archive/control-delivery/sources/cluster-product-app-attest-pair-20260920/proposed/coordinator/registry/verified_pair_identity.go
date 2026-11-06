package registry

import (
	"encoding/hex"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (m VerifiedPairMember) controlPublicKey() string {
	if m.Identity.Kind == protocol.NativeIdentityAppAttest {
		return m.Identity.ControlPublicKey
	}
	return m.SEPublicKey
}

func (r *Registry) appAttestVerifiedPairMemberLocked(p *Provider, now time.Time) (VerifiedPairMember, error) {
	identity, ok := r.appAttestNativeIdentityLocked(p, now)
	if !ok {
		return VerifiedPairMember{}, ErrVerifiedPairUnavailable
	}
	return VerifiedPairMember{Identity: identity, ProviderID: identity.ProviderID,
		ProcessPublicKey: identity.ProcessPublicKey, ProviderBinaryHash: hex.EncodeToString(identity.BinarySHA256[:]),
		ProviderMetallibHash: hex.EncodeToString(identity.MetallibSHA256[:]), ReleasePolicyGeneration: identity.ReleasePolicyGeneration}, nil
}

// Legacy projection uses genuine existing fields; no serial or SE assertion is
// synthesized for App Attest. Only typed v2 hashing needs this projection.
func (m VerifiedPairMember) canonicalIdentity() (protocol.NativeMemberIdentity, error) {
	if m.Identity.Kind != 0 {
		if m.Identity.Kind != protocol.NativeIdentityAppAttest || m.DeviceSerial != "" || m.SEPublicKey != "" ||
			m.ProviderID != m.Identity.ProviderID || m.ProcessPublicKey != m.Identity.ProcessPublicKey ||
			m.ProviderBinaryHash != hex.EncodeToString(m.Identity.BinarySHA256[:]) ||
			m.ProviderMetallibHash != hex.EncodeToString(m.Identity.MetallibSHA256[:]) || m.ReleasePolicyGeneration != m.Identity.ReleasePolicyGeneration {
			return protocol.NativeMemberIdentity{}, ErrVerifiedPairInput
		}
		return m.Identity, m.Identity.Validate()
	}
	binary, bOK := nativeIdentityHash(m.ProviderBinaryHash)
	metal, mOK := nativeIdentityHash(m.ProviderMetallibHash)
	if !bOK || !mOK {
		return protocol.NativeMemberIdentity{}, ErrVerifiedPairInput
	}
	identity := protocol.NativeMemberIdentity{Kind: protocol.NativeIdentityLegacyMDA,
		ProviderID: m.ProviderID, ControlPublicKey: m.SEPublicKey, ProcessPublicKey: m.ProcessPublicKey,
		BinarySHA256: binary, MetallibSHA256: metal, ReleasePolicyGeneration: m.ReleasePolicyGeneration, DeviceSerial: m.DeviceSerial}
	return identity, identity.Validate()
}

func verifiedPairTranscriptVersion(m VerifiedPairMembership) uint8 {
	if m.Members[0].Identity.Kind == 0 && m.Members[1].Identity.Kind == 0 {
		return 1
	}
	return 2
}

func verifiedPairTranscript(m VerifiedPairMembership) [32]byte {
	if m.TranscriptVersion != 0 && m.TranscriptVersion != verifiedPairTranscriptVersion(m) {
		return [32]byte{}
	}
	if verifiedPairTranscriptVersion(m) == 1 {
		return verifiedPairLegacyTranscript(m)
	}
	var identities [2]protocol.NativeMemberIdentity
	for rank, member := range m.Members {
		identity, err := member.canonicalIdentity()
		if err != nil {
			return [32]byte{}
		}
		identities[rank] = identity
	}
	digest, err := (protocol.NativePairTypedMembership{Epoch: m.Epoch, Generation: m.Generation,
		Model: m.Model, PlanSHA256: m.PlanSHA256, ProposedRuntimeBindingSHA256: m.ProposedRuntimeBindingSHA256,
		Suite: m.Suite, PrepareBeforeUnixNano: m.PrepareBefore.UnixNano(), ExpiresAtUnixNano: m.ExpiresAt.UnixNano(), Members: identities}).Digest()
	if err != nil {
		return [32]byte{}
	}
	return digest
}

func verifiedPairUsesAppAttest(s *verifiedPairState, p *Provider) bool {
	if s == nil {
		return false
	}
	rank := verifiedPairRank(s, p)
	return rank >= 0 && s.membership.Members[rank].Identity.Kind == protocol.NativeIdentityAppAttest
}

// Caller holds Registry and this provider's lock. This checks immutable proof,
// not capacity or route admission; it may be used during release/reconciliation.
func (r *Registry) verifiedPairAuthorityMatchesLocked(s *verifiedPairState, p *Provider, now time.Time) bool {
	if s == nil {
		return true
	}
	rank := verifiedPairRank(s, p)
	if rank < 0 || r.providers[p.ID] != p || p.registry != r || p.untrustEpoch.Load() != s.untrust[rank] {
		return false
	}
	m := s.membership.Members[rank]
	if m.Identity.Kind != 0 {
		identity, ok := r.appAttestNativeIdentityLocked(p, now)
		return ok && identity == m.Identity
	}
	legacy, err := r.legacyVerifiedPairMemberLocked(p, now)
	return err == nil && legacy == m
}

// A legacy flag setter may revalidate an independent App Attest authority, but
// explicit security failures and disconnects must always terminate admission.
func (r *Registry) revokeVerifiedPairForProvider(p *Provider) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.disconnectVerifiedPairLocked(p)
}

// Caller holds Registry; this uses only immutable state and captured pointers.
func (r *Registry) invalidateAppAttestVerifiedPairLocked(p *Provider) {
	if s := r.verifiedPairs.connections[p]; s != nil && verifiedPairUsesAppAttest(s, p) {
		r.endVerifiedPairLocked(s)
	}
}

// Called after Grant releases its provider lock. Acquire both member locks in
// the existing order. A refresh can reschedule current expiry, never revive a
// stopped generation or extend the original pair lifetime.
func (r *Registry) refreshAppAttestVerifiedPair(p *Provider) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.verifiedPairs.connections[p]
	if s == nil || !verifiedPairUsesAppAttest(s, p) || (s.phase != VerifiedPairPending && s.phase != VerifiedPairActive) {
		return
	}
	unlock := lockVerifiedPairMembers(s.providers)
	defer unlock()
	if r.validateVerifiedPairLocked(s, time.Now(), false) == nil {
		r.scheduleVerifiedPairDeadlineLocked(s)
	}
}
