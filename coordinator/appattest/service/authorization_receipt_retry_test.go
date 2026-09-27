package service

import (
	"context"
	"encoding/json"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFirstProofWaitsForRiskReceiptWithEarlyBoundedRetries(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, record, state := newAuthorizationFixture(t)
		x := sessionForAuthorization(s, p, record)
		x.servingIdentityReady = false
		initial := state
		initial.Receipt = &store.AppAttestReceipt{
			Outcome: "verified", Details: json.RawMessage(`{"type":"ATTEST"}`),
			ExpiresAt: state.Receipt.ExpiresAt, NextAt: time.Now().Add(time.Minute),
		}
		e := record.evidence
		applyAppAttestReadiness(&e, initial)
		verdict := appattest.EvaluateAuthorization(e, time.Now())
		if verdict.Outcome != "unknown" || !e.RevocationKnown || !e.ReceiptVerified {
			t.Fatal("fixture must have a verified initial receipt but no risk metric")
		}
		// The first retry may race Apple's one-minute receipt renewal. Keep
		// waiting safely with bounded backoff until that distinct proof arrives.
		for _, delay := range []time.Duration{time.Minute, 5 * time.Minute} {
			x.updateServingAuthorization(&record.status, e, verdict)
			if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.authorizer.current[p] != nil {
				t.Fatal("an ATTEST receipt without a risk metric granted serving")
			}
			if got := x.nextAssertionDelay(); got != delay {
				t.Fatalf("first risk receipt retry delay=%s, want %s", got, delay)
			}
			time.Sleep(delay)
		}
		if err := s.RefreshBuildQualifications(context.Background()); err != nil {
			t.Fatal(err)
		}
		e.AssertionAt = time.Now()
		applyAppAttestReadiness(&e, state)
		st := &delayedHistoryStore{MemoryStore: store.NewMemory(store.Config{}), readiness: state, t: t,
			continuity: store.MachineContinuity{Machine: store.MachineIdentity{ID: "machine", Assurance: "key_bound"}}}
		s.store = st
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		lease, ok := s.registry.ProviderServingAuthorization(p)
		if !ok || lease.IssuedAt != e.AssertionAt || st.lookups != 1 || !x.servingIdentityReady {
			t.Fatal("fresh risk receipt did not recover through identity and policy gates")
		}
		if x.nextAssertionDelay() != shadowAssertionInterval || x.readinessRetryFailures != 0 {
			t.Fatal("successful receipt readiness did not restore normal assertion cadence")
		}
	})
}

func TestRiskReceiptRetryDoesNotReplaceRetainedProofOrIgnoreDenial(t *testing.T) {
	for _, retained := range []bool{false, true} {
		s, p, record, state := newAuthorizationFixture(t)
		x := sessionForAuthorization(s, p, record)
		if retained {
			s.authorizer.remember(p, record)
		}
		e := record.evidence
		applyAppAttestReadiness(&e, state)
		e.RiskMetric = nil
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		want := time.Minute
		if retained {
			want = shadowAssertionInterval
			if s.authorizer.current[p] != record {
				t.Fatal("receipt readiness replaced existing proof")
			}
		}
		if got := x.nextAssertionDelay(); got != want {
			t.Fatalf("retained=%v delay=%s, want %s", retained, got, want)
		}
		e.CodeMeasurementMatched = false
		x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
		if s.registry.ProviderServingDenialReason(p) == "" || x.nextAssertionDelay() != shadowAssertionInterval {
			t.Fatal("missing risk metric concealed a verified code mismatch")
		}
	}
}

func TestUnverifiedEnrollmentReceiptRetriesFirstGrantWithoutSkippingRiskCheck(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	x := sessionForAuthorization(s, p, record)
	initial := state
	initial.Receipt = nil // Renewal has not produced a verified risk receipt.
	e := record.evidence
	applyAppAttestReadiness(&e, initial)
	verdict := appattest.EvaluateAuthorization(e, time.Now())
	if verdict.Outcome != "unknown" || e.ReceiptVerified || e.RiskMetric != nil {
		t.Fatal("fixture must lack a verified receipt and risk metric")
	}
	for _, want := range []time.Duration{time.Minute, 5 * time.Minute, shadowAssertionInterval} {
		x.updateServingAuthorization(&record.status, e, verdict)
		if _, granted := s.registry.ProviderServingAuthorization(p); granted || s.authorizer.current[p] != nil {
			t.Fatal("unverified enrollment receipt granted serving or retained proof")
		}
		if got := x.nextAssertionDelay(); got != want {
			t.Fatalf("first-grant receipt retry delay=%s, want %s", got, want)
		}
	}
	// A fresh assertion after independent receipt renewal may grant normally.
	s.store = &statusReadinessStore{MemoryStore: store.NewMemory(store.Config{}), state: state}
	e.AssertionAt = time.Now().UTC()
	applyAppAttestReadiness(&e, state)
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	if _, granted := s.registry.ProviderServingAuthorization(p); !granted {
		t.Fatal("verified risk receipt did not recover first grant")
	}
	if got := x.nextAssertionDelay(); got != shadowAssertionInterval {
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
			s, p, record, _ := newAuthorizationFixture(t)
			x := sessionForAuthorization(s, p, record)
			e := record.evidence
			applyAppAttestReadiness(&e, store.AppAttestReadiness{})
			tc.edit(&e)
			x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
			if got := x.nextAssertionDelay(); got != shadowAssertionInterval {
				t.Fatalf("unsafe early retry scheduled: %s", got)
			}
			if _, granted := s.registry.ProviderServingAuthorization(p); granted {
				t.Fatal("missing receipt or signed denial granted serving")
			}
		})
	}
}
