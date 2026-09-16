package service

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func sessionForAuthorization(s *Service, p *registry.Provider, record *appAttestAuthorizationRecord) *Session {
	return &Session{s: s, provider: p, protocolVersion: 3, id: record.proofSession,
		account: record.evidence.Binding.Account, servingIdentityReady: true,
		key: &store.AppAttestShadowKey{KeyID: record.evidence.Binding.Credential}}
}

func makeLegacyAuthorized(p *registry.Provider) {
	p.SetAttested(true, registry.TrustHardware)
	p.CodeAttested, p.ChallengeVerifiedSIP = true, true
	p.SetLastChallengeVerified(time.Now())
}

func TestFreshRevokedCredentialFencesCurrentConnectionBeforeFirstGrant(t *testing.T) {
	for _, phase := range []string{"initial readiness", "second readiness", "refresh readiness"} {
		t.Run(phase, func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			makeLegacyAuthorized(p)
			p.RequireVerifiedMachineIdentity()
			if !s.registry.ProviderLegacyServingAuthorized(p) || p.GetAppAttestServingAuthorization().CredentialID != "" {
				t.Fatal("fixture must have only legacy authorization")
			}
			x := sessionForAuthorization(s, p, record)
			e := record.evidence
			applyAppAttestReadiness(&e, state)
			switch phase {
			case "initial readiness":
				e.Revoked = true
				x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
			case "second readiness":
				s.store = &statusReadinessStore{MemoryStore: store.NewMemory(store.Config{}), state: store.AppAttestReadiness{Revoked: true}}
				x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
			case "refresh readiness":
				s.store = &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{e.Binding.Credential: {Revoked: true}}}
				s.authorizer.remember(p, record)
				s.authorizer.refresh(context.Background())
			}
			if s.registry.ProviderServingDenialReason(p) == "" || s.registry.ProviderLegacyServingAuthorized(p) {
				t.Fatal("freshly proven revoked key fell back to legacy authorization")
			}
			if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.authorizer.current[p] != nil {
				t.Fatal("revoked credential retained serving or refresh state")
			}
			if s.authorizer.apply(p, record, state, time.Now()) {
				t.Fatal("late non-revoked snapshot resurrected the connection")
			}
		})
	}
}

func TestUnknownReadinessRetainsProofAndLeaseWithoutExtendingDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, record, state := newAuthorizationFixture(t)
		a := s.authorizer
		a.remember(p, record)
		if !a.apply(p, record, state, time.Now()) {
			t.Fatal("initial grant")
		}
		before := p.GetAppAttestServingAuthorization()
		x := sessionForAuthorization(s, p, record)
		e := record.evidence
		applyAppAttestReadiness(&e, state)
		e.RevocationKnown = false
		verdict := appattest.EvaluateAuthorization(e, time.Now())
		if verdict.Outcome != "unknown" {
			t.Fatal("unknown fixture")
		}
		x.updateServingAuthorization(&record.status, e, verdict)
		if p.GetAppAttestServingAuthorization() != before || a.current[p] != record {
			t.Fatal("unknown assertion verdict discarded or extended the prior proof")
		}
		st := &authorizationBatchStore{Store: s.store, err: errors.New("temporary readiness outage")}
		s.store = st
		a.refresh(context.Background())
		st.err = nil // A missing batch entry also conveys unknown readiness.
		a.refresh(context.Background())
		if p.GetAppAttestServingAuthorization() != before || a.current[p] != record {
			t.Fatal("unknown refresh changed the lease or removed recovery state")
		}
		// Policy-level unknowns must not clear a known prior lease either.
		if a.apply(p, record, store.AppAttestReadiness{}, time.Now()) {
			t.Fatal("unknown receipt granted a new lease")
		}
		if p.GetAppAttestServingAuthorization() != before {
			t.Fatal("unknown receipt changed deadline")
		}
		time.Sleep(appAttestRevocationFreshness + time.Nanosecond)
		if _, ok := s.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("unknown evidence survived lease expiry")
		}
		// Recovery reuses the old verified proof; it must not manufacture a new
		// assertion timestamp or extend past that original signature's limit.
		st.state = map[string]store.AppAttestReadiness{record.evidence.Binding.Credential: state}
		a.refresh(context.Background())
		after, ok := s.registry.ProviderServingAuthorization(p)
		if !ok || after.IssuedAt != before.IssuedAt || after.ValidUntil.After(before.IssuedAt.Add(appattest.AssertionFreshness)) {
			t.Fatal("bounded refresh recovery failed or manufactured a fresh assertion")
		}
		time.Sleep(appattest.AssertionFreshness)
		a.refresh(context.Background())
		if _, ok := s.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("stale signature recovered")
		}
	})
}

func TestUnknownReadinessCannotMaskSignedNegativeEvidence(t *testing.T) {
	for _, violation := range []string{"hardware", "code"} {
		t.Run(violation, func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			s.authorizer.remember(p, record)
			if !s.authorizer.apply(p, record, state, time.Now()) {
				t.Fatal("grant")
			}
			makeLegacyAuthorized(p)
			x := sessionForAuthorization(s, p, record)
			e := record.evidence
			applyAppAttestReadiness(&e, state)
			e.RevocationKnown = false
			if violation == "hardware" {
				e.HardwareMatched = false
			} else {
				e.CodeMeasurementMatched = false
			}
			verdict := appattest.EvaluateAuthorization(e, time.Now())
			if verdict.Outcome != "ineligible" {
				t.Fatal("negative did not override unknown")
			}
			x.updateServingAuthorization(&record.status, e, verdict)
			if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.registry.ProviderLegacyServingAuthorized(p) || s.authorizer.current[p] != nil {
				t.Fatal("unknown state concealed a confirmed signed violation")
			}
		})
	}
}
