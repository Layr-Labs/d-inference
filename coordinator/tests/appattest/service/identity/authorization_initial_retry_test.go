package identity_test

import (
	"context"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestFirstProofReadinessOutageRetriesEarlyAndRecovers(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, _, state := newAuthorizationFixture(t)
		x := identityForAuthorization(s, p, nil)
		e := s.evidence
		eligibility.ApplyReadiness(&e, state)
		e.RevocationKnown = false // The point readiness lookup failed.
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		if s.authorizer.Current(p) != nil || p.GetAppAttestServingAuthorization().CredentialID != "" {
			t.Fatal("unknown first proof granted permission or bypassed identity resolution")
		}
		if delay := x.NextAssertionDelay(); delay != time.Minute {
			t.Fatalf("first readiness retry delay=%s, want one minute", delay)
		}
		time.Sleep(time.Minute)
		if err := s.RefreshBuildQualifications(context.Background()); err != nil {
			t.Fatal(err)
		}
		// The retry supplies a new verified assertion. The recovered lookup
		// must still qualify it before any refresh record or grant is created.
		e.AssertionAt = time.Now()
		eligibility.ApplyReadiness(&e, state)
		st := &delayedHistoryStore{MemoryStore: memorystore.NewMemory(store.Config{}), readiness: state, t: t,
			continuity: store.MachineContinuity{Machine: store.MachineIdentity{ID: "machine", Assurance: "key_bound"}}}
		s.store = st
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		lease, ok := s.registry.ProviderServingAuthorization(p)
		if !ok || lease.IssuedAt != e.AssertionAt || s.authorizer.Current(p) == nil {
			t.Fatal("fresh verified retry did not recover after readiness returned")
		}
		if _, machine := p.GetVerifiedMachineIdentity(); machine != e.Binding.Machine || st.lookups != 1 {
			t.Fatal("first authorization skipped canonical identity resolution")
		}
		if delay := x.NextAssertionDelay(); delay != recovery.AssertionInterval {
			t.Fatal("successful qualification did not restore normal assertion cadence")
		}
		// A later first-grant outage starts again at one minute, not five.
		s.authorizer.Forget(p)
		e.RevocationKnown = false
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		if x.NextAssertionDelay() != time.Minute {
			t.Fatal("successful qualification did not reset retry failures")
		}
	})
}

func TestFirstProofReadinessRetriesAreBoundedAndNeverAuthorizeUnknown(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	x := identityForAuthorization(s, p, nil)
	e := s.evidence
	eligibility.ApplyReadiness(&e, state)
	e.RevocationKnown = false
	for _, want := range []time.Duration{time.Minute, 5 * time.Minute, recovery.AssertionInterval, recovery.AssertionInterval} {
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		if got := x.NextAssertionDelay(); got != want {
			t.Fatalf("retry delay=%s, want %s", got, want)
		}
		if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.authorizer.Current(p) != nil {
			t.Fatal("retry scheduling granted unknown evidence")
		}
	}
	// A retained proof already recovers on the five-second authorizer refresh;
	// do not replace it or multiply assertion traffic for that separate case.
	s.authorizer.Remember(p, record)
	x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
	if x.NextAssertionDelay() != recovery.AssertionInterval || s.authorizer.Current(p) != record {
		t.Fatal("existing proof was replaced or retried instead of refreshed")
	}
}

func TestInitialReadinessRetryDoesNotOverrideSignedNegativeEvidence(t *testing.T) {
	s, p, _, state := newAuthorizationFixture(t)
	x := identityForAuthorization(s, p, nil)
	e := s.evidence
	eligibility.ApplyReadiness(&e, state)
	e.RevocationKnown = false
	x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
	if x.NextAssertionDelay() != time.Minute {
		t.Fatal("initial retry was not scheduled")
	}
	e.CodeMeasurementMatched = false
	x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
	if x.NextAssertionDelay() != recovery.AssertionInterval || s.registry.ProviderServingDenialReason(p) == "" {
		t.Fatal("signed negative evidence retained the early retry or escaped denial")
	}
}
