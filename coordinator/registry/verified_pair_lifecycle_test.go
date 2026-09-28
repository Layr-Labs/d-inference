package registry

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestVerifiedPairPendingDisconnectAndExpiryDoNotQuarantine(t *testing.T) {
	for _, disconnect := range []bool{false, true} {
		for prepared := 0; prepared <= 2; prepared++ {
			t.Run(fmt.Sprintf("disconnect_%t_prepared_%d", disconnect, prepared), func(t *testing.T) {
				r, members, request := pairTestRegistry(t)
				h, m := pairTestReserve(t, r, members, request)
				for rank := 0; rank < prepared; rank++ {
					members[rank].mu.Lock()
					members[rank].BackendCapacity.Slots = nil
					members[rank].mu.Unlock()
					if err := r.AcknowledgeVerifiedPairPrepared(h, members[rank], m.TranscriptSHA256); err != nil {
						t.Fatal(err)
					}
				}
				if disconnect {
					r.Disconnect(members[0].ID)
					members[0] = pairTestMember(t, r, members[0].ID, "serial-a")
				} else {
					r.mu.Lock()
					r.expireVerifiedPairsLocked(m.PrepareBefore)
					r.mu.Unlock()
				}
				pairTestDone(t, h)
				if _, err := r.CommitVerifiedPairOwners(h); !errors.Is(err, ErrVerifiedPairStale) {
					t.Fatal("late Commit revived ended preparation")
				}
				if _, _, err := r.ReserveVerifiedPair(members, request); err != nil {
					t.Fatalf("never-started hold quarantined device: %v", err)
				}
			})
		}
	}
}

func TestVerifiedPairActiveDisconnectQuarantinesHardwareAcrossReconnect(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	h, m := pairTestActive(t, r, members, request)
	old := members[0]
	r.Disconnect(old.ID)
	pairTestDone(t, h)
	replacement := pairTestMember(t, r, old.ID, "serial-a")
	if replacement == old {
		t.Fatal("test did not create actual replacement connection")
	}
	if err := r.ObserveVerifiedPairOwnerReleased(h, replacement, m.TranscriptSHA256); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("reconnect manufactured old owner's release")
	}
	if err := r.ObserveVerifiedPairOwnerReleased(h, old, m.TranscriptSHA256); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("disconnected connection released native ownership")
	}
	if _, _, err := r.ReserveVerifiedPair([2]*Provider{replacement, members[1]}, request); !errors.Is(err, ErrVerifiedPairBusy) {
		t.Fatal("reconnect escaped physical hold")
	}
	if findRoutableProvider(r, pairTestModel) != nil {
		t.Fatal("reconnect routed solo over quarantined native state")
	}
	r.mu.Lock()
	r.expireVerifiedPairsLocked(m.ExpiresAt.Add(time.Hour))
	r.mu.Unlock()
	status, err := r.VerifiedPairStatus(h)
	if err != nil || status.Phase != VerifiedPairQuarantined || status.Released != [2]bool{} {
		t.Fatal("time fabricated cleanup")
	}
}

func TestVerifiedPairActiveExpiryAndCancelRequireBothReleaseObservations(t *testing.T) {
	for _, expiry := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "expiry"}[expiry], func(t *testing.T) {
			r, members, request := pairTestRegistry(t)
			h, m := pairTestActive(t, r, members, request)
			if expiry {
				r.mu.Lock()
				r.expireVerifiedPairsLocked(m.ExpiresAt)
				r.mu.Unlock()
			} else if err := r.CancelVerifiedPair(h); err != nil {
				t.Fatal(err)
			}
			pairTestDone(t, h)
			status, err := r.VerifiedPairStatus(h)
			if err != nil || status.Phase != VerifiedPairQuarantined || status.Released != [2]bool{} {
				t.Fatal("missing quarantine")
			}
			for _, p := range members {
				if err := r.ObserveVerifiedPairOwnerReleased(h, p, m.TranscriptSHA256); err != nil {
					t.Fatal(err)
				}
			}
			if _, _, err := r.ReserveVerifiedPair(members, request); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestVerifiedPairStrictIdentityAndFreshnessGates(t *testing.T) {
	cases := map[string]func(*Registry, *Provider){
		"hardware":           func(_ *Registry, p *Provider) { p.MDAVerified = false },
		"se_binding":         func(_ *Registry, p *Provider) { p.SEKeyBound = false },
		"fresh_code":         func(_ *Registry, p *Provider) { p.FreshCodeAttested = false },
		"process_key":        func(_ *Registry, p *Provider) { p.AttestationResult.EncryptionPublicKey = "" },
		"challenge_stale":    func(_ *Registry, p *Provider) { p.LastChallengeVerified = time.Now().Add(-challengeFreshnessMaxAge) },
		"challenge_future":   func(_ *Registry, p *Provider) { p.LastChallengeVerified = time.Now().Add(time.Minute) },
		"heartbeat":          func(_ *Registry, p *Provider) { p.LastHeartbeat = time.Now().Add(-verifiedPairHeartbeatLimit) },
		"release_generation": func(_ *Registry, p *Provider) { p.ApplicationEvidence.PolicyGeneration-- },
		"release_process":    func(_ *Registry, p *Provider) { p.ApplicationEvidence.ProcessPublicKey = "" },
		"release_freshness": func(_ *Registry, p *Provider) {
			p.ApplicationEvidence.VerifiedAt = time.Now().Add(-challengeFreshnessMaxAge)
		},
		"state_restore": func(_ *Registry, p *Provider) { p.stateRestorePending = true },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			r, members, request := pairTestRegistry(t)
			members[1].mu.Lock()
			mutate(r, members[1])
			members[1].mu.Unlock()
			if _, _, err := r.ReserveVerifiedPair(members, request); err == nil {
				t.Fatal("unverified/stale member admitted")
			}
			r.mu.RLock()
			count := len(r.verifiedPairs.states)
			r.mu.RUnlock()
			if count != 0 {
				t.Fatal("failed second member retained partial reservation")
			}
		})
	}
}

func TestVerifiedPairRevocationClosesGrantWithoutResurrection(t *testing.T) {
	t.Run("runtime_policy_false_restore", func(t *testing.T) {
		r, members, request := pairTestRegistry(t)
		h, _ := pairTestActive(t, r, members, request)
		// Actual API policy paths mutate these flags, then reconcile, without a
		// separate MarkUntrusted call. Unchanged refresh must retain the grant.
		if err := r.ReconcileAttestedRuntimeCapabilities(members[0].ID); err != nil {
			t.Fatal(err)
		}
		select {
		case <-h.Done():
			t.Fatal("successful unchanged refresh revoked pair")
		default:
		}
		members[0].mu.Lock()
		members[0].RuntimeVerified, members[0].RuntimeManifestChecked, members[0].MetallibVerified = false, false, false
		members[0].mu.Unlock()
		if err := r.ReconcileAttestedRuntimeCapabilities(members[0].ID); err != nil {
			t.Fatal(err)
		}
		pairTestDone(t, h)
		members[0].mu.Lock()
		members[0].RuntimeVerified, members[0].RuntimeManifestChecked, members[0].MetallibVerified = true, true, true
		members[0].mu.Unlock()
		if err := r.ReconcileAttestedRuntimeCapabilities(members[0].ID); err != nil {
			t.Fatal(err)
		}
		if _, err := r.ValidateVerifiedPair(h); err == nil {
			t.Fatal("runtime policy restoration revived old grant")
		}
	})
	t.Run("late_reconcile_old_state", func(t *testing.T) {
		r, members, request := pairTestRegistry(t)
		old, _ := pairTestReserve(t, r, members, request)
		captured := old.state
		if err := r.CancelVerifiedPair(old); err != nil {
			t.Fatal(err)
		}
		current, _ := pairTestReserve(t, r, members, request)
		r.invalidateVerifiedPairState(captured)
		select {
		case <-current.Done():
			t.Fatal("late old reconciliation invalidated replacement")
		default:
		}
	})
	cases := map[string]func(*Registry, *Provider){
		"hard_untrust":      func(r *Registry, p *Provider) { r.MarkUntrusted(p.ID) },
		"transient_untrust": func(r *Registry, p *Provider) { r.MarkUntrustedTransient(p.ID); r.RecordChallengeSuccess(p.ID) },
		"challenge_failure": func(r *Registry, p *Provider) { r.RecordChallengeFailure(p.ID, false) },
		"release_clear":     func(_ *Registry, p *Provider) { p.ClearApplicationEvidence() },
		"code_clear":        func(_ *Registry, p *Provider) { p.SetCodeAttested(false) },
		"trust_downgrade":   func(r *Registry, p *Provider) { r.SetTrustLevel(p.ID, TrustSelfSigned) },
		"policy_generation": func(r *Registry, _ *Provider) {
			r.SetReleasePolicyGeneration(8, true, func(ApplicationEvidence) bool { return true })
		},
	}
	for name, revoke := range cases {
		t.Run(name, func(t *testing.T) {
			r, members, request := pairTestRegistry(t)
			h, _ := pairTestActive(t, r, members, request)
			revoke(r, members[0])
			pairTestDone(t, h)
			if _, err := r.ValidateVerifiedPair(h); err == nil {
				t.Fatal("revoked grant resurrected")
			}
			status, err := r.VerifiedPairStatus(h)
			if err != nil || status.Phase != VerifiedPairQuarantined {
				t.Fatal("revocation freed possible native owner")
			}
		})
	}
}

func TestVerifiedPairRevalidationBindsCurrentMembership(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	h, m := pairTestActive(t, r, members, request)
	members[1].mu.Lock()
	members[1].ApplicationEvidence.BinaryHash = members[0].ApplicationEvidence.MetallibHash
	members[1].mu.Unlock()
	if _, err := r.ValidateVerifiedPair(h); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("changed binary identity remained authorized")
	}
	pairTestDone(t, h)
	if m.TranscriptSHA256 != verifiedPairTranscript(m) {
		t.Fatal("external snapshot changed with live provider")
	}
}

func TestVerifiedPairActualTimerNeverExtendsLifetime(t *testing.T) {
	t.Run("provider_lock_wait", func(t *testing.T) {
		r, members, request := pairTestRegistry(t)
		request.Lifetime = 450 * time.Millisecond
		type reservation struct {
			handle     *VerifiedPairHandle
			membership VerifiedPairMembership
			err        error
		}
		result := make(chan reservation, 1)
		members[0].mu.Lock()
		locked := true
		defer func() {
			if locked {
				members[0].mu.Unlock()
			}
		}()
		go func() { h, m, err := r.ReserveVerifiedPair(members, request); result <- reservation{h, m, err} }()
		// No other registry operation is active: the writer failing this read try
		// proves Reserve has captured its original clock and is waiting on p.mu.
		limit := time.Now().Add(time.Second)
		observed := false
		for time.Now().Before(limit) {
			if !r.mu.TryRLock() {
				observed = true
				break
			}
			r.mu.RUnlock()
			time.Sleep(time.Millisecond)
		}
		if !observed {
			members[0].mu.Unlock()
			locked = false
			t.Fatal("reservation did not reach member lock")
		}
		time.Sleep(200 * time.Millisecond)
		members[0].mu.Unlock()
		locked = false
		var got reservation
		select {
		case got = <-result:
		case <-time.After(time.Second):
			t.Fatal("reservation did not finish after lock release")
		}
		if got.err != nil {
			t.Fatal(got.err)
		}
		// Old scheduling code added the 200ms lock wait a second time. Allow timer
		// scheduling jitter, but not that second interval after the absolute expiry.
		timeout := time.NewTimer(time.Until(got.membership.PrepareBefore.Add(75 * time.Millisecond)))
		defer timeout.Stop()
		select {
		case <-got.handle.Done():
		case <-timeout.C:
			t.Fatal("provider lock wait extended absolute preparation expiry")
		}
	})
	for _, active := range []bool{false, true} {
		t.Run(map[bool]string{false: "pending", true: "active"}[active], func(t *testing.T) {
			r, members, request := pairTestRegistry(t)
			request.Lifetime = 200 * time.Millisecond
			h, m := pairTestReserve(t, r, members, request)
			if active {
				pairTestPrepare(t, r, h, members, m)
				committed, err := r.CommitVerifiedPairOwners(h)
				if err != nil || committed.ExpiresAt != m.ExpiresAt {
					t.Fatal("commit reset original lifetime")
				}
			}
			select {
			case <-h.Done():
			case <-time.After(2 * time.Second):
				t.Fatal("timer failed to invalidate")
			}
			r.mu.RLock()
			held := len(r.verifiedPairs.states)
			r.mu.RUnlock()
			if (active && held != 1) || (!active && held != 0) {
				t.Fatal("timer confused pending with active cleanup")
			}
		})
	}
}
