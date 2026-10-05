package identity_test

import (
	"context"
	"encoding/json"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestFirstProofWaitsForRiskReceiptWithEarlyBoundedRetries(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, _, state := newAuthorizationFixture(t)
		x := identityForAuthorization(s, p, nil)
		initial := state
		initial.Receipt = &store.AppAttestReceipt{
			Outcome: "verified", Details: json.RawMessage(`{"type":"ATTEST"}`),
			ExpiresAt: state.Receipt.ExpiresAt, NextAt: time.Now().Add(time.Minute),
		}
		e := s.evidence
		eligibility.ApplyReadiness(&e, initial)
		verdict := appattest.EvaluateAuthorization(e, time.Now())
		if verdict.Outcome != "unknown" || !e.RevocationKnown || !e.ReceiptVerified {
			t.Fatal("fixture must have a verified initial receipt but no risk metric")
		}
		// The first retry may race Apple's one-minute receipt renewal. Keep
		// waiting safely with bounded backoff until that distinct proof arrives.
		for _, delay := range []time.Duration{time.Minute, 5 * time.Minute} {
			x.Update(s.proof(e), verdict)
			if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.authorizer.Current(p) != nil {
				t.Fatal("an ATTEST receipt without a risk metric granted serving")
			}
			if got := x.NextAssertionDelay(); got != delay {
				t.Fatalf("first risk receipt retry delay=%s, want %s", got, delay)
			}
			time.Sleep(delay)
		}
		if err := s.RefreshBuildQualifications(context.Background()); err != nil {
			t.Fatal(err)
		}
		e.AssertionAt = time.Now()
		eligibility.ApplyReadiness(&e, state)
		st := &delayedHistoryStore{MemoryStore: memorystore.NewMemory(store.Config{}), readiness: state, t: t,
			continuity: store.MachineContinuity{Machine: store.MachineIdentity{ID: "machine", Assurance: "key_bound"}}}
		s.store = st
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		lease, ok := s.registry.ProviderServingAuthorization(p)
		_, machine := p.GetVerifiedMachineIdentity()
		if !ok || lease.IssuedAt != e.AssertionAt || st.lookups != 1 || machine != e.Binding.Machine {
			t.Fatal("fresh risk receipt did not recover through identity and policy gates")
		}
		if x.NextAssertionDelay() != recovery.AssertionInterval {
			t.Fatal("successful receipt readiness did not restore normal assertion cadence")
		}
		s.authorizer.Forget(p)
		e.RiskMetric = nil
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		if x.NextAssertionDelay() != time.Minute {
			t.Fatal("successful receipt readiness did not reset retry failures")
		}
	})
}

func TestRiskReceiptRetryDoesNotReplaceRetainedProofOrIgnoreDenial(t *testing.T) {
	for _, retained := range []bool{false, true} {
		s, p, record, state := newAuthorizationFixture(t)
		x := identityForAuthorization(s, p, nil)
		if retained {
			s.authorizer.Remember(p, record)
		}
		e := s.evidence
		eligibility.ApplyReadiness(&e, state)
		e.RiskMetric = nil
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		want := time.Minute
		if retained {
			want = recovery.AssertionInterval
			if s.authorizer.Current(p) != record {
				t.Fatal("receipt readiness replaced existing proof")
			}
		}
		if got := x.NextAssertionDelay(); got != want {
			t.Fatalf("retained=%v delay=%s, want %s", retained, got, want)
		}
		e.CodeMeasurementMatched = false
		x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
		if s.registry.ProviderServingDenialReason(p) == "" || x.NextAssertionDelay() != recovery.AssertionInterval {
			t.Fatal("missing risk metric concealed a verified code mismatch")
		}
	}
}

func TestUnverifiedEnrollmentReceiptRetriesFirstGrantWithoutSkippingRiskCheck(t *testing.T) {
	s, p, _, state := newAuthorizationFixture(t)
	x := identityForAuthorization(s, p, nil)
	initial := state
	initial.Receipt = nil // Renewal has not produced a verified risk receipt.
	e := s.evidence
	eligibility.ApplyReadiness(&e, initial)
	verdict := appattest.EvaluateAuthorization(e, time.Now())
	if verdict.Outcome != "unknown" || e.ReceiptVerified || e.RiskMetric != nil {
		t.Fatal("fixture must lack a verified receipt and risk metric")
	}
	for _, want := range []time.Duration{time.Minute, 5 * time.Minute, recovery.AssertionInterval} {
		x.Update(s.proof(e), verdict)
		if _, granted := s.registry.ProviderServingAuthorization(p); granted || s.authorizer.Current(p) != nil {
			t.Fatal("unverified enrollment receipt granted serving or retained proof")
		}
		if got := x.NextAssertionDelay(); got != want {
			t.Fatalf("first-grant receipt retry delay=%s, want %s", got, want)
		}
	}
	// A fresh assertion after independent receipt renewal may grant normally.
	s.store = &statusReadinessStore{MemoryStore: memorystore.NewMemory(store.Config{}), state: state}
	e.AssertionAt = time.Now().UTC()
	eligibility.ApplyReadiness(&e, state)
	x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
	if _, granted := s.registry.ProviderServingAuthorization(p); !granted {
		t.Fatal("verified risk receipt did not recover first grant")
	}
	if got := x.NextAssertionDelay(); got != recovery.AssertionInterval {
		t.Fatalf("grant did not restore normal assertion cadence: %s", got)
	}
}

func TestMissingReceiptDoesNotRetryEarlyWithoutRenewalOrAfterSignedDenial(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*appattest.AuthorizationEvidence)
	}{
		{"renewal unavailable", func(e *appattest.AuthorizationEvidence) { e.RenewalConfigured = false }},
		{"signed code mismatch", func(e *appattest.AuthorizationEvidence) { e.CodeMeasurementMatched = false }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, p, _, _ := newAuthorizationFixture(t)
			x := identityForAuthorization(s, p, nil)
			e := s.evidence
			eligibility.ApplyReadiness(&e, store.AppAttestReadiness{})
			tc.edit(&e)
			x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
			if got := x.NextAssertionDelay(); got != recovery.AssertionInterval {
				t.Fatalf("unsafe early retry scheduled: %s", got)
			}
			if _, granted := s.registry.ProviderServingAuthorization(p); granted {
				t.Fatal("missing receipt or signed denial granted serving")
			}
		})
	}
}
