package registry

import (
	"crypto/rand"
	"time"
)

// ReserveVerifiedPair atomically excludes both devices from ordinary routing
// and model commands. The arguments are exact live Registry connection objects
// selected by the coordinator, never provider IDs supplied by a peer. Rank order
// is preserved. This returns a preparation hold, NOT permission to start owners.
func (r *Registry) ReserveVerifiedPair(members [2]*Provider, request VerifiedPairRequest) (*VerifiedPairHandle, VerifiedPairMembership, error) {
	var empty VerifiedPairMembership
	if !validVerifiedPairRequest(request) || members[0] == nil || members[1] == nil ||
		members[0] == members[1] || members[0].ID == members[1].ID {
		return nil, empty, ErrVerifiedPairInput
	}
	var epoch [16]byte
	if _, err := rand.Read(epoch[:]); err != nil {
		return nil, empty, ErrVerifiedPairUnavailable
	}
	epoch[6] = (epoch[6] & 0x0f) | 0x40
	epoch[8] = (epoch[8] & 0x3f) | 0x80
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	r.expireVerifiedPairsLocked(now)
	if !r.initializeVerifiedPairsLocked() {
		return nil, empty, ErrVerifiedPairBusy
	}
	unlock := lockVerifiedPairMembers(members)
	defer unlock()
	m := VerifiedPairMembership{Epoch: epoch, Model: request.Model, PlanSHA256: request.PlanSHA256,
		ProposedRuntimeBindingSHA256: request.ProposedRuntimeBindingSHA256, Suite: VerifiedPairSuite,
		PrepareBefore: now.Add(verifiedPairPreparationLimit), ExpiresAt: now.Add(request.Lifetime)}
	if m.ExpiresAt.Before(m.PrepareBefore) {
		m.PrepareBefore = m.ExpiresAt
	}
	for rank, p := range members {
		if r.providerPairHeldLocked(p, now, nil) {
			return nil, empty, ErrVerifiedPairBusy
		}
		member, err := r.verifiedPairMemberLocked(p, request.Model, now, nil)
		if err != nil {
			return nil, empty, err
		}
		if !r.verifiedPairIdleLocked(p, false) {
			return nil, empty, ErrVerifiedPairBusy
		}
		m.Members[rank] = member
	}
	if m.Members[0].DeviceSerial == m.Members[1].DeviceSerial ||
		m.Members[0].SEPublicKey == m.Members[1].SEPublicKey ||
		m.Members[0].ProcessPublicKey == m.Members[1].ProcessPublicKey {
		return nil, empty, ErrVerifiedPairInput
	}
	if r.verifiedPairHasDuplicateConnectionLocked(members, m.Members) {
		return nil, empty, ErrVerifiedPairBusy
	}
	// Provider lock waits and identity work consume the original preparation
	// budget. Never publish an already-expired pending grant with a new interval.
	if !time.Now().Before(m.PrepareBefore) {
		return nil, empty, ErrVerifiedPairStale
	}
	r.verifiedPairs.generation++
	m.Generation = r.verifiedPairs.generation
	m.TranscriptSHA256 = verifiedPairTranscript(m)
	s := &verifiedPairState{membership: m, providers: members, phase: VerifiedPairPending, done: make(chan struct{})}
	for rank, p := range members {
		s.untrust[rank] = p.untrustEpoch.Load()
		r.verifiedPairs.connections[p] = s
		for _, key := range verifiedPairDeviceKeys(m.Members[rank]) {
			r.verifiedPairs.devices[key] = s
		}
	}
	r.verifiedPairs.states[s] = struct{}{}
	r.scheduleVerifiedPairDeadlineLocked(s, now)
	return &VerifiedPairHandle{registry: r, state: s}, m, nil
}

// AcknowledgeVerifiedPairPrepared is called only for an authenticated control
// response on p's exact connection after local solo teardown, canonical device
// exclusion and proposed-runtime verification. Owners MUST NOT start from this
// acknowledgment. Empty heartbeat slots alone are not a preparation receipt.
// Native runtime approval and that local implementation remain separate gates.
func (r *Registry) AcknowledgeVerifiedPairPrepared(h *VerifiedPairHandle, p *Provider, transcript [32]byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, err := r.verifiedPairHandleLocked(h)
	if err != nil {
		return err
	}
	if s.phase != VerifiedPairPending {
		return ErrVerifiedPairPhase
	}
	rank := verifiedPairRank(s, p)
	if rank < 0 || transcript != s.membership.TranscriptSHA256 || s.prepared[rank] {
		return ErrVerifiedPairStale
	}
	unlock := lockVerifiedPairMembers(s.providers)
	defer unlock()
	if err := r.validateVerifiedPairLocked(s, time.Now(), false); err != nil {
		return err
	}
	if !r.verifiedPairIdleLocked(p, true) {
		return ErrVerifiedPairBusy
	}
	s.prepared[rank] = true
	return nil
}

// CommitVerifiedPairOwners is the start-authorization linearization point.
// After success, even failed/delayed delivery may have started owners: neither
// cancellation, EOF, timeout nor reconnect may release the device holds. The
// caller must already have approved the native binding and must complete fresh
// authenticated key establishment before allowing RDMA inference records.
func (r *Registry) CommitVerifiedPairOwners(h *VerifiedPairHandle) (VerifiedPairMembership, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, err := r.verifiedPairHandleLocked(h)
	if err != nil {
		return VerifiedPairMembership{}, err
	}
	if s.phase != VerifiedPairPending || !s.prepared[0] || !s.prepared[1] {
		return VerifiedPairMembership{}, ErrVerifiedPairPhase
	}
	unlock := lockVerifiedPairMembers(s.providers)
	defer unlock()
	now := time.Now()
	if err := r.validateVerifiedPairLocked(s, now, true); err != nil {
		return VerifiedPairMembership{}, err
	}
	if !time.Now().Before(s.membership.PrepareBefore) {
		r.endVerifiedPairLocked(s)
		return VerifiedPairMembership{}, ErrVerifiedPairStale
	}
	s.phase = VerifiedPairActive
	r.scheduleVerifiedPairDeadlineLocked(s, now)
	return s.membership, nil
}

// ValidateVerifiedPair rechecks CURRENT gates/identity before each new native
// request/key use. It does not refresh the original preparation or lifetime
// deadline. Callers must also listen to Done; no authorization API can promise
// that revocation will never occur immediately after it returns.
func (r *Registry) ValidateVerifiedPair(h *VerifiedPairHandle) (VerifiedPairMembership, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, err := r.verifiedPairHandleLocked(h)
	if err != nil {
		return VerifiedPairMembership{}, err
	}
	if s.phase != VerifiedPairActive {
		return VerifiedPairMembership{}, ErrVerifiedPairPhase
	}
	unlock := lockVerifiedPairMembers(s.providers)
	defer unlock()
	if err := r.validateVerifiedPairLocked(s, time.Now(), false); err != nil {
		return VerifiedPairMembership{}, err
	}
	return s.membership, nil
}

// Caller holds r.mu plus both provider locks. Membership equality excludes the
// normal challenge refresh timestamp, but binds approved release generation and
// immutable identity/code hashes. An untrust/recovery cycle cannot resurrect it.
func (r *Registry) validateVerifiedPairLocked(s *verifiedPairState, now time.Time, requireEmpty bool) error {
	deadline := s.membership.ExpiresAt
	if s.phase == VerifiedPairPending {
		deadline = s.membership.PrepareBefore
	}
	if !now.Before(deadline) {
		r.endVerifiedPairLocked(s)
		return ErrVerifiedPairStale
	}
	for rank, p := range s.providers {
		member, err := r.verifiedPairMemberLocked(p, s.membership.Model, now, s)
		if err != nil || member != s.membership.Members[rank] || p.untrustEpoch.Load() != s.untrust[rank] {
			r.endVerifiedPairLocked(s)
			return ErrVerifiedPairStale
		}
		if (requireEmpty || s.phase == VerifiedPairActive) && !r.verifiedPairIdleLocked(p, true) {
			r.endVerifiedPairLocked(s)
			return ErrVerifiedPairBusy
		}
	}
	return nil
}

// Deterministic provider lock order; registry write lock excludes all ordinary
// solo commits and replacement/disconnection. No IO or callbacks run here.
func lockVerifiedPairMembers(members [2]*Provider) func() {
	first, second := members[0], members[1]
	if first.ID > second.ID {
		first, second = second, first
	}
	first.mu.Lock()
	second.mu.Lock()
	return func() { second.mu.Unlock(); first.mu.Unlock() }
}
