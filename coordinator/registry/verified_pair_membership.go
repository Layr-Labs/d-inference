package registry

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"math"
	"time"
	"unicode/utf8"
)

func validVerifiedPairRequest(request VerifiedPairRequest) bool {
	return request.Model != "" && len(request.Model) <= 512 && utf8.ValidString(request.Model) &&
		request.PlanSHA256 != [32]byte{} && request.ProposedRuntimeBindingSHA256 != [32]byte{} &&
		request.Lifetime > 0 && request.Lifetime <= verifiedPairLifetimeLimit
}

// Caller holds Registry.mu and both provider locks. A pair never relaxes trust
// for an owner self-route. It reuses the same routing gate chain as solo,
// followed by stricter opt-in hardware/process/release identity requirements.
func (r *Registry) verifiedPairMemberLocked(p *Provider, model string, now time.Time, except *verifiedPairState) (VerifiedPairMember, error) {
	var empty VerifiedPairMember
	if p == nil || len(p.ID) == 0 || len(p.ID) > 128 || !utf8.ValidString(p.ID) || r.providers[p.ID] != p || p.registry != r {
		return empty, ErrVerifiedPairStale
	}
	// Membership is an identity and trust decision, not an admission decision.
	// A control-only member reports "draining" on every heartbeat because it
	// refuses solo work, and cooldowns, the breaker and ejection record how
	// requests fared on this machine. Routing a request to the pair honors all
	// of them; the pair's existence depends on none.
	if !r.pairMemberLiveLocked(p, except, model, RequestTraits{}, now) {
		return empty, ErrVerifiedPairUnavailable
	}
	a := p.AttestationResult
	if !p.Attested || p.TrustLevel != TrustHardware || !p.MDAVerified || !p.SEKeyBound ||
		!p.CodeAttested || !p.FreshCodeAttested || !p.MetallibVerified ||
		a == nil || !a.Valid || !a.SecureEnclaveAvailable || a.SerialNumber == "" || a.PublicKey == "" ||
		len(a.SerialNumber) > 128 || len(a.PublicKey) > 256 ||
		a.EncryptionPublicKey != p.PublicKey ||
		!freshVerifiedPairTime(p.LastHeartbeat, now, verifiedPairHeartbeatLimit) ||
		!freshVerifiedPairTime(p.LastChallengeVerified, now, challengeFreshnessMaxAge) ||
		r.releasePolicyGeneration == 0 || !r.providerHoldsCurrentApplicationEvidenceLocked(p) ||
		!freshVerifiedPairTime(p.ApplicationEvidence.VerifiedAt, now, challengeFreshnessMaxAge) {
		return empty, ErrVerifiedPairUnavailable
	}
	key, err := base64.StdEncoding.DecodeString(p.PublicKey)
	if err != nil || len(key) != 32 || base64.StdEncoding.EncodeToString(key) != p.PublicKey {
		return empty, ErrVerifiedPairUnavailable
	}
	e := p.ApplicationEvidence
	if !verifiedPairSHA(e.BinaryHash) || !verifiedPairSHA(e.MetallibHash) {
		return empty, ErrVerifiedPairUnavailable
	}
	return VerifiedPairMember{
		ProviderID: p.ID, DeviceSerial: a.SerialNumber, SEPublicKey: a.PublicKey,
		ProcessPublicKey: p.PublicKey, ProviderBinaryHash: e.BinaryHash,
		ProviderMetallibHash: e.MetallibHash, ReleasePolicyGeneration: e.PolicyGeneration,
	}, nil
}

// pairMemberLiveLocked is the liveness, catalog and trait check a pair member
// must pass for model, on its own pair's hold. A pair never relaxes trust,
// private-only admission or the catalog for its owner. It deliberately leaves
// out what governs routing a request rather than the pair's existence: the
// drain mark, which a control-only member carries for as long as it runs, and
// the request-fault trackers (cooldowns, breaker, ejection). Caller holds r.mu
// and p.mu.
func (r *Registry) pairMemberLiveLocked(p *Provider, pair *verifiedPairState, model string, traits RequestTraits, now time.Time) bool {
	ok, _ := (&ProviderEligibility{registry: r}).livenessAllowPairLocked(p, r.MinTrustLevel, false, now, pair, true)
	return ok && r.providerServesRoutableModelLocked(p, model, false) && r.providerEligibleForTraitsLocked(p, model, traits)
}

func freshVerifiedPairTime(observed, now time.Time, limit time.Duration) bool {
	return !observed.IsZero() && !observed.After(now) && now.Sub(observed) < limit
}

func verifiedPairSHA(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// No remote timestamp or duration is used as a local clock. Transcript bytes
// use a closed domain and length-delimited fields; they contain no inference
// payload or private key. These are produced locally, not decoded from peers.
func verifiedPairTranscript(m VerifiedPairMembership) [32]byte {
	b := append([]byte("darkbloom/coordinator-pair-membership/v1\x00"), m.Epoch[:]...)
	b = binary.BigEndian.AppendUint64(b, m.Generation)
	appendString := func(s string) { b = binary.BigEndian.AppendUint32(b, uint32(len(s))); b = append(b, s...) }
	appendString(m.Model)
	b = append(b, m.PlanSHA256[:]...)
	b = append(b, m.ProposedRuntimeBindingSHA256[:]...)
	appendString(m.Suite)
	b = binary.BigEndian.AppendUint64(b, uint64(m.PrepareBefore.UnixNano()))
	b = binary.BigEndian.AppendUint64(b, uint64(m.ExpiresAt.UnixNano()))
	for rank, member := range m.Members {
		b = append(b, byte(rank))
		appendString(member.ProviderID)
		appendString(member.DeviceSerial)
		appendString(member.SEPublicKey)
		appendString(member.ProcessPublicKey)
		appendString(member.ProviderBinaryHash)
		appendString(member.ProviderMetallibHash)
		b = binary.BigEndian.AppendUint64(b, member.ReleasePolicyGeneration)
	}
	return sha256.Sum256(b)
}

// Existing pending requests and sent/planned load commands must settle before
// selection. Idle resident weights are allowed during PREPARATION only: they
// are not treated as unloaded. Commit additionally requires a current empty
// authoritative slot snapshot plus both local preparation acknowledgments.
func (r *Registry) verifiedPairIdleLocked(p *Provider, prepared bool) bool {
	if len(p.pendingReqs) != 0 || p.pairModelCommandsInFlight != 0 || r.providerHasPendingLoad(p.ID) {
		return false
	}
	if p.BackendCapacity == nil {
		return false
	}
	if prepared && (len(p.BackendCapacity.Slots) != 0 || p.CurrentModel != "" || len(p.WarmModels) != 0) {
		return false
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.NumRunning != 0 || slot.NumWaiting != 0 || slot.ActiveTokens != 0 ||
			slot.ActiveTokenBudgetUsed != 0 || slot.QueuedTokenBudget != 0 || slot.MaxTokensPotential != 0 ||
			(slot.State != "idle" && slot.State != "running" && slot.State != "unloaded") {
			return false
		}
	}
	return true
}

func (r *Registry) initializeVerifiedPairsLocked() bool {
	if r.verifiedPairs.generation == math.MaxUint64 {
		return false
	}
	if r.verifiedPairs.states == nil {
		r.verifiedPairs.states = make(map[*verifiedPairState]struct{})
		r.verifiedPairs.connections = make(map[*Provider]*verifiedPairState)
		r.verifiedPairs.devices = make(map[string]*verifiedPairState)
	}
	return len(r.verifiedPairs.states) < verifiedPairMaximumHeld
}
