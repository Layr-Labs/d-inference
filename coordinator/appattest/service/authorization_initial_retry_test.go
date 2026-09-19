package service

import (
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFirstProofReadinessOutageRetriesEarlyAndRecovers(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, record, state := newAuthorizationFixture(t)
		x := sessionForAuthorization(s, p, record)
		x.servingIdentityReady = false
		e := record.evidence
		applyAppAttestReadiness(&e, state)
		e.RevocationKnown = false // The point readiness lookup failed.
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		if s.authorizer.current[p] != nil || p.GetAppAttestServingAuthorization().CredentialID != "" {
			t.Fatal("unknown first proof granted permission or bypassed identity resolution")
		}
		if delay := x.nextAssertionDelay(); delay != time.Minute {
			t.Fatalf("first readiness retry delay=%s, want one minute", delay)
		}
		time.Sleep(time.Minute)
		// The retry supplies a new verified assertion. The recovered lookup
		// must still qualify it before any refresh record or grant is created.
		e.AssertionAt = time.Now()
		applyAppAttestReadiness(&e, state)
		st := &delayedHistoryStore{MemoryStore: store.NewMemory(store.Config{}), readiness: state, t: t,
			continuity: store.MachineContinuity{Machine: store.MachineIdentity{ID: "machine", Assurance: "key_bound"}}}
		s.store = st
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		lease, ok := s.registry.ProviderServingAuthorization(p)
		if !ok || lease.IssuedAt != e.AssertionAt || s.authorizer.current[p] == nil {
			t.Fatal("fresh verified retry did not recover after readiness returned")
		}
		if !x.servingIdentityReady || st.lookups != 1 {
			t.Fatal("first authorization skipped canonical identity resolution")
		}
		if delay := x.nextAssertionDelay(); delay != shadowAssertionInterval || x.readinessRetryFailures != 0 {
			t.Fatal("successful qualification did not restore normal assertion cadence")
		}
	})
}

func TestFirstProofReadinessRetriesAreBoundedAndNeverAuthorizeUnknown(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	x := sessionForAuthorization(s, p, record)
	e := record.evidence
	applyAppAttestReadiness(&e, state)
	e.RevocationKnown = false
	for _, want := range []time.Duration{time.Minute, 5 * time.Minute, shadowAssertionInterval, shadowAssertionInterval} {
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		if got := x.nextAssertionDelay(); got != want {
			t.Fatalf("retry delay=%s, want %s", got, want)
		}
		if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.authorizer.current[p] != nil {
			t.Fatal("retry scheduling granted unknown evidence")
		}
	}
	// A retained proof already recovers on the five-second authorizer refresh;
	// do not replace it or multiply assertion traffic for that separate case.
	s.authorizer.remember(p, record)
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	if x.nextAssertionDelay() != shadowAssertionInterval || s.authorizer.current[p] != record {
		t.Fatal("existing proof was replaced or retried instead of refreshed")
	}
}

func TestInitialReadinessRetryDoesNotOverrideSignedNegativeEvidence(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	x := sessionForAuthorization(s, p, record)
	e := record.evidence
	applyAppAttestReadiness(&e, state)
	e.RevocationKnown = false
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	if x.nextAssertionDelay() != time.Minute {
		t.Fatal("initial retry was not scheduled")
	}
	e.CodeMeasurementMatched = false
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	if x.nextAssertionDelay() != shadowAssertionInterval || s.registry.ProviderServingDenialReason(p) == "" {
		t.Fatal("signed negative evidence retained the early retry or escaped denial")
	}
}
