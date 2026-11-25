package registry

import "time"

func (r *Registry) verifiedPairHandleLocked(h *VerifiedPairHandle) (*verifiedPairState, error) {
	if h == nil || h.registry != r || h.state == nil {
		return nil, ErrVerifiedPairStale
	}
	if _, exists := r.verifiedPairs.states[h.state]; !exists {
		return nil, ErrVerifiedPairStale
	}
	return h.state, nil
}

// CancelVerifiedPair frees pending preparation only. Once Commit succeeded it
// closes admissions and quarantines the physical holds until actual release.
func (r *Registry) CancelVerifiedPair(h *VerifiedPairHandle) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, err := r.verifiedPairHandleLocked(h)
	if err != nil {
		return err
	}
	r.endVerifiedPairLocked(s)
	return nil
}

// ObserveVerifiedPairOwnerReleased must be called only from the authenticated
// ORIGINAL connection's release handler, after that provider observed native
// cleanup AND the actual owner lease-release ACK. It records that observation;
// this layer cannot independently inspect remote native memory or a journal.
// A timer, write failure, EOF, PID absence or reconnect is never such a receipt.
// The future wire handler must use its connection object, not a peer-supplied ID.
func (r *Registry) ObserveVerifiedPairOwnerReleased(h *VerifiedPairHandle, p *Provider, transcript [32]byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, err := r.verifiedPairHandleLocked(h)
	if err != nil {
		return err
	}
	if s.phase != VerifiedPairActive && s.phase != VerifiedPairQuarantined {
		return ErrVerifiedPairPhase
	}
	rank := verifiedPairRank(s, p)
	if rank < 0 || r.providers[p.ID] != p || transcript != s.membership.TranscriptSHA256 || s.released[rank] {
		return ErrVerifiedPairStale
	}
	p.mu.Lock()
	m := s.membership.Members[rank]
	a := p.AttestationResult
	// Cleanup need not pass capacity/model-routability gates, but a now-untrusted
	// process cannot erase an uncertain device hold. Missing fresh identity/code
	// evidence requires a separate administrative fence, which this API omits.
	bound := a != nil && a.Valid && a.SecureEnclaveAvailable && a.SerialNumber == m.DeviceSerial && a.PublicKey == m.SEPublicKey &&
		a.EncryptionPublicKey == m.ProcessPublicKey && p.PublicKey == m.ProcessPublicKey &&
		p.Attested && p.TrustLevel == TrustHardware && p.MDAVerified && p.SEKeyBound &&
		p.Status != StatusUntrusted && p.Status != StatusOffline && p.CodeAttested && p.FreshCodeAttested &&
		p.RuntimeVerified && p.RuntimeManifestChecked && p.MetallibVerified && p.ChallengeVerifiedSIP &&
		r.providerHoldsCurrentApplicationEvidenceLocked(p) &&
		p.ApplicationEvidence.BinaryHash == m.ProviderBinaryHash && p.ApplicationEvidence.MetallibHash == m.ProviderMetallibHash &&
		freshVerifiedPairTime(p.LastChallengeVerified, time.Now(), challengeFreshnessMaxAge)
	if m.Identity.Kind != 0 {
		identity, ok := r.appAttestNativeIdentityLocked(p, time.Now())
		bound = ok && sameVerifiedPairCleanupIdentity(m.Identity, identity) && p.untrustEpoch.Load() == s.untrust[rank]
	}
	p.mu.Unlock()
	if !bound {
		return ErrVerifiedPairStale
	}
	s.released[rank] = true
	r.quarantineVerifiedPairLocked(s)
	if s.released[0] && s.released[1] {
		r.releaseVerifiedPairLocked(s)
	}
	return nil
}

func (r *Registry) VerifiedPairStatus(h *VerifiedPairHandle) (VerifiedPairStatus, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, err := r.verifiedPairHandleLocked(h)
	if err != nil {
		return VerifiedPairStatus{}, err
	}
	r.expireVerifiedPairsLocked(time.Now())
	return VerifiedPairStatus{Membership: s.membership, Phase: s.phase, Prepared: s.prepared, Released: s.released}, nil
}

func verifiedPairRank(s *verifiedPairState, p *Provider) int {
	if p != nil {
		for rank, member := range s.providers {
			if member == p {
				return rank
			}
		}
	}
	return -1
}

// Caller holds r.mu and p.mu. A reconnect with the same verified hardware
// identity remains excluded, while its new connection can never consume the old
// handle. Identity loss on the original connection also cannot evade its hold.
func (r *Registry) providerPairHeldLocked(p *Provider, now time.Time, except *verifiedPairState) bool {
	if len(r.verifiedPairs.states) == 0 {
		return false
	}
	held := func(s *verifiedPairState) bool {
		return s != nil && s != except && s.phase != VerifiedPairReleased &&
			(s.phase != VerifiedPairPending || now.Before(s.membership.PrepareBefore))
	}
	if held(r.verifiedPairs.connections[p]) {
		return true
	}
	for _, key := range verifiedPairObservedDeviceKeysLocked(p) {
		if held(r.verifiedPairs.devices[key]) {
			return true
		}
	}
	return false
}

// Caller holds r.mu. Disconnect also holds the disconnecting p.mu, while trust
// revocation may not; this helper reads no provider fields or other locks.
// A never-start-authorized pending grant is safe to cancel;
// possible native ownership is retained independently of live registry entries.
func (r *Registry) disconnectVerifiedPairLocked(p *Provider) {
	if s := r.verifiedPairs.connections[p]; s != nil {
		r.endVerifiedPairLocked(s)
	}
}

// Call only after releasing p.mu. Loss notifications refer to the observed
// object, so a late challenge from a disconnected socket cannot revoke a new
// connection's replacement grant merely because its textual ID was reused.
func (r *Registry) invalidateVerifiedPairForProvider(p *Provider) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.verifiedPairs.connections[p]
	if s == nil {
		return
	}
	if !verifiedPairUsesAppAttest(s, p) {
		r.endVerifiedPairLocked(s)
		return
	}
	p.mu.Lock()
	valid := r.verifiedPairAuthorityMatchesLocked(s, p, time.Now())
	p.mu.Unlock()
	if !valid {
		r.endVerifiedPairLocked(s)
	}
}

// Invalidation observed during a policy reconciliation belongs to the exact
// captured grant, even if another generation replaced it before this lock.
func (r *Registry) invalidateVerifiedPairState(s *verifiedPairState) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.verifiedPairs.states[s]; exists {
		r.endVerifiedPairLocked(s)
	}
}

func (r *Registry) endVerifiedPairLocked(s *verifiedPairState) {
	if s.phase == VerifiedPairPending {
		r.releaseVerifiedPairLocked(s)
	} else {
		r.quarantineVerifiedPairLocked(s)
	}
}

func (r *Registry) closeVerifiedPairDoneLocked(s *verifiedPairState) {
	if !s.doneClosed {
		close(s.done)
		s.doneClosed = true
	}
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
}

func (r *Registry) quarantineVerifiedPairLocked(s *verifiedPairState) {
	if s.phase == VerifiedPairReleased {
		return
	}
	s.phase = VerifiedPairQuarantined
	r.closeVerifiedPairDoneLocked(s)
}

func (r *Registry) releaseVerifiedPairLocked(s *verifiedPairState) {
	s.phase = VerifiedPairReleased
	r.closeVerifiedPairDoneLocked(s)
	for rank, p := range s.providers {
		if r.verifiedPairs.connections[p] == s {
			delete(r.verifiedPairs.connections, p)
		}
		for _, key := range s.deviceKeys[rank] {
			if r.verifiedPairs.devices[key] == s {
				delete(r.verifiedPairs.devices, key)
			}
		}
	}
	delete(r.verifiedPairs.states, s)
}

func (r *Registry) expireVerifiedPairsLocked(now time.Time) {
	for s := range r.verifiedPairs.states {
		deadline := s.membership.ExpiresAt
		if s.phase == VerifiedPairPending {
			deadline = s.membership.PrepareBefore
		}
		if !now.Before(deadline) {
			r.endVerifiedPairLocked(s)
		}
	}
}

// Timers are bound to an exact state pointer, never an ID lookup. They check
// the earliest fixed lifetime/heartbeat/challenge expiry; a fresh heartbeat may
// move only its own freshness deadline, never the original session lifetime.
func (r *Registry) scheduleVerifiedPairDeadlineLocked(s *verifiedPairState) {
	if s.timer != nil {
		s.timer.Stop()
	}
	deadline := s.membership.ExpiresAt
	if s.phase == VerifiedPairPending {
		deadline = s.membership.PrepareBefore
	}
	for rank, p := range s.providers {
		deadlines := []time.Time{p.LastHeartbeat.Add(verifiedPairHeartbeatLimit)}
		if s.membership.Members[rank].Identity.Kind != 0 {
			deadlines = append(deadlines, p.appAttestAuthorization.ValidUntil)
		} else {
			deadlines = append(deadlines, p.LastChallengeVerified.Add(challengeFreshnessMaxAge), p.ApplicationEvidence.VerifiedAt.Add(challengeFreshnessMaxAge))
		}
		for _, d := range deadlines {
			if d.Before(deadline) {
				deadline = d
			}
		}
	}
	wait := time.Until(deadline)
	if wait < 0 {
		wait = 0
	}
	s.timer = time.AfterFunc(wait, func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		if _, exists := r.verifiedPairs.states[s]; !exists || (s.phase != VerifiedPairPending && s.phase != VerifiedPairActive) {
			return
		}
		unlock := lockVerifiedPairMembers(s.providers)
		defer unlock()
		now := time.Now()
		if r.validateVerifiedPairLocked(s, now, false) == nil {
			r.scheduleVerifiedPairDeadlineLocked(s)
		}
	})
}
