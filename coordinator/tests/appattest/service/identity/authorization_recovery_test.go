package identity_test

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

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
			x := identityForAuthorization(s, p, nil)
			e := s.evidence
			eligibility.ApplyReadiness(&e, state)
			switch phase {
			case "initial readiness":
				e.Revoked = true
				x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
			case "second readiness":
				s.store = &statusReadinessStore{MemoryStore: memorystore.NewMemory(store.Config{}), state: store.AppAttestReadiness{Revoked: true}}
				x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
			case "refresh readiness":
				s.store = &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{e.Binding.Credential: {Revoked: true}}}
				s.authorizer.Remember(p, record)
				s.authorizer.Refresh(context.Background())
			}
			if s.registry.ProviderServingDenialReason(p) == "" || s.registry.ProviderLegacyServingAuthorized(p) {
				t.Fatal("freshly proven revoked key fell back to legacy authorization")
			}
			if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.authorizer.Current(p) != nil {
				t.Fatal("revoked credential retained serving or refresh state")
			}
			if s.authorizer.Apply(p, record, state, time.Now()) {
				t.Fatal("late non-revoked snapshot resurrected the connection")
			}
		})
	}
}

func TestUnknownReadinessRetainsProofAndLeaseWithoutExtendingDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, record, state := newAuthorizationFixture(t)
		a := s.authorizer
		a.Remember(p, record)
		if !a.Apply(p, record, state, time.Now()) {
			t.Fatal("initial grant")
		}
		before := p.GetAppAttestServingAuthorization()
		x := identityForAuthorization(s, p, nil)
		e := s.evidence
		eligibility.ApplyReadiness(&e, state)
		e.RevocationKnown = false
		verdict := appattest.EvaluateAuthorization(e, time.Now())
		if verdict.Outcome != "unknown" {
			t.Fatal("unknown fixture")
		}
		x.Update(s.proof(e), verdict)
		if p.GetAppAttestServingAuthorization() != before || a.Current(p) != record {
			t.Fatal("unknown assertion verdict discarded or extended the prior proof")
		}
		st := &authorizationBatchStore{Store: s.store, err: errors.New("temporary readiness outage")}
		s.store = st
		a.Refresh(context.Background())
		st.err = nil // A missing batch entry also conveys unknown readiness.
		a.Refresh(context.Background())
		if p.GetAppAttestServingAuthorization() != before || a.Current(p) != record {
			t.Fatal("unknown refresh changed the lease or removed recovery state")
		}
		// Policy-level unknowns must not clear a known prior lease either.
		if a.Apply(p, record, store.AppAttestReadiness{}, time.Now()) {
			t.Fatal("unknown receipt granted a new lease")
		}
		if p.GetAppAttestServingAuthorization() != before {
			t.Fatal("unknown receipt changed deadline")
		}
		time.Sleep(authorization.RevocationFreshness + time.Nanosecond)
		if _, ok := s.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("unknown evidence survived lease expiry")
		}
		// Recovery reuses the old verified proof; it must not manufacture a new
		// assertion timestamp or extend past that original signature's limit.
		st.state = map[string]store.AppAttestReadiness{s.evidence.Binding.Credential: state}
		builds, _ := store.As[store.AppAttestBuildStore](st.Store)
		if err := s.qualifications.Refresh(context.Background(), builds, s.registry.SetAppAttestQualificationGeneration); err != nil {
			t.Fatal(err)
		}
		a.Refresh(context.Background())
		after, ok := s.registry.ProviderServingAuthorization(p)
		if !ok || after.IssuedAt != before.IssuedAt || after.ValidUntil.After(before.IssuedAt.Add(appattest.AssertionFreshness)) {
			t.Fatal("bounded refresh recovery failed or manufactured a fresh assertion")
		}
		time.Sleep(appattest.AssertionFreshness)
		a.Refresh(context.Background())
		if _, ok := s.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("stale signature recovered")
		}
	})
}

func TestUnknownReadinessCannotMaskSignedNegativeEvidence(t *testing.T) {
	for _, violation := range []string{"hardware", "code"} {
		t.Run(violation, func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			s.authorizer.Remember(p, record)
			if !s.authorizer.Apply(p, record, state, time.Now()) {
				t.Fatal("grant")
			}
			makeLegacyAuthorized(p)
			x := identityForAuthorization(s, p, nil)
			e := s.evidence
			eligibility.ApplyReadiness(&e, state)
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
			x.Update(s.proof(e), verdict)
			if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.registry.ProviderLegacyServingAuthorized(p) || s.authorizer.Current(p) != nil {
				t.Fatal("unknown state concealed a confirmed signed violation")
			}
		})
	}
}
