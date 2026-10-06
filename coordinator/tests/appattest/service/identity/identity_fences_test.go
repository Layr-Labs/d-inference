package identity_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type blockedIdentityReadiness struct {
	*statusReadinessStore
	entered chan struct{}
	release chan struct{}
}

func (s *blockedIdentityReadiness) GetAppAttestReadiness(context.Context, string) (store.AppAttestReadiness, error) {
	close(s.entered)
	<-s.release
	return s.state, nil
}

func TestIdentityLateReadinessCannotOutrunProofFence(t *testing.T) {
	for _, fence := range []string{"drop", "revocation", "replacement"} {
		t.Run(fence, func(t *testing.T) {
			f, p, replacement, state := newAuthorizationFixture(t)
			base := f.store.(*statusReadinessStore)
			st := &blockedIdentityReadiness{statusReadinessStore: base, entered: make(chan struct{}), release: make(chan struct{})}
			f.store = st
			x := identityForAuthorization(f, p, nil)
			e := f.evidence
			eligibility.ApplyReadiness(&e, state)
			var integrity evidence.Integrity
			proof := authorization.NewVerifiedProof(e, &f.status, "proof", integrity.Dropped, integrity.Baseline())
			done := make(chan string, 1)
			go func() { done <- x.Update(proof, appattest.EvaluateAuthorization(e, time.Now())) }()
			<-st.entered
			if f.authorizer.Current(p) == nil {
				t.Fatal("readiness read began before proof retention")
			}
			switch fence {
			case "drop":
				integrity.Drop(f.authorizer, p)
			case "revocation":
				f.RevokeCredential(e.Binding.Credential)
			case "replacement":
				f.authorizer.Remember(p, replacement)
			}
			close(st.release)
			if result := <-done; result == "granted" {
				t.Fatal("late readiness read granted a fenced proof")
			}
			if _, granted := f.registry.ProviderServingAuthorization(p); granted {
				t.Fatal("late readiness response installed a lease")
			}
			if fence == "replacement" {
				if f.authorizer.Current(p) != replacement {
					t.Fatal("stale readiness replaced current proof")
				}
			} else if f.authorizer.Current(p) != nil {
				t.Fatal("fenced proof was retained")
			}
		})
	}
}

func TestVerifiedProofSnapshotsAuthenticatedValues(t *testing.T) {
	f, p, _, state := newAuthorizationFixture(t)
	x := identityForAuthorization(f, p, nil)
	e := f.evidence
	eligibility.ApplyReadiness(&e, state)
	status := f.status
	proof := authorization.NewVerifiedProof(e, &status, "proof", nil, 0)
	*e.ValidationCategory = 0
	*e.RiskMetric = 1000
	status.BinaryHash = "changed after verification"
	if result := x.Update(proof, appattest.AuthorizationVerdict{Outcome: "eligible"}); result != "granted" {
		t.Fatalf("caller mutation changed the retained verified proof: %s", result)
	}
	if _, granted := f.registry.ProviderServingAuthorization(p); !granted {
		t.Fatal("immutable verified proof did not grant")
	}
}

func TestMissingSignedStatusClearsFirstGrantRetry(t *testing.T) {
	f, p, _, state := newAuthorizationFixture(t)
	x := identityForAuthorization(f, p, nil)
	e := f.evidence
	eligibility.ApplyReadiness(&e, state)
	e.RevocationKnown = false
	x.Update(f.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
	if x.NextAssertionDelay() != time.Minute {
		t.Fatal("readiness outage did not schedule initial retry")
	}
	proof := authorization.NewVerifiedProof(e, nil, "proof", nil, 0)
	if result := x.Update(proof, appattest.EvaluateAuthorization(e, time.Now())); result != "serving_unavailable" {
		t.Fatalf("missing status result=%s", result)
	}
	if x.NextAssertionDelay() != recovery.AssertionInterval {
		t.Fatal("missing signed status retained readiness retry state")
	}
	if f.authorizer.Current(p) != nil {
		t.Fatal("missing signed status retained proof")
	}
}
