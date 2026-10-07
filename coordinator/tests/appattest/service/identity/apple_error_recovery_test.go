package identity_test

import (
	"context"
	"reflect"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/observation"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAppleErrorRetriesExchangeWithBoundedBackoff(t *testing.T) {
	for _, phase := range []string{"ready", "attestation", "assertion"} {
		t.Run(phase, func(t *testing.T) {
			s, p, _, _ := newAuthorizationFixture(t)
			h := &rotationHarness{mem: s.store.(*statusReadinessStore).MemoryStore}
			x := h.exchange(3, p)
			x.attempt.Challenge.Binding.Session = "proof"
			x.attempt.Challenge.Credential = &store.AppAttestShadowKey{KeyID: s.evidence.Binding.Credential}
			x.deps.Authorization = s.authorizer
			var policies []string
			observeFailure := func(reason string) {
				s.authorizer.RejectProof(p, reason)
				fields := observation.Format(observation.Event{Provider: p, Stage: "prospective_policy", Outcome: recovery.FailurePolicyOutcome(reason)}).Fields
				if fields["stage"] == "prospective_policy" {
					policies = append(policies, fields["outcome"].(string))
				}
			}
			attempts := 0
			previous := x.attempt.Challenge.Binding.Session
			var delays []time.Duration
			x.drive(context.Background(), func(ctx context.Context, binding recovery.Binding) recovery.Outcome {
				attempts++
				if attempts > 1 {
					if binding.Session == previous || x.attempt.Challenge.Credential != nil || x.attempt.Challenge.Binding.Challenge != "" || x.attempt.Challenge.Expected != "" {
						t.Fatal("retry reused the failed exchange or cached acceptance")
					}
					previous = binding.Session
				}
				x.attempt.Challenge.Expected, x.attempt.Challenge.Binding.Challenge = phase, "fresh-challenge"
				result := "apple_error"
				if attempts == 4 {
					result = "unsupported" // A permanent response still ends retries.
				}
				if next := x.accept(ctx, protocol.AppAttestShadowPayload{
					Session: binding.Session, Action: phase, Result: result,
				}); next != "stop" || x.last.Outcome != result {
					t.Fatalf("exchange next=%s outcome=%s", next, x.last.Outcome)
				}
				return recovery.Outcome{Reason: x.last.Outcome, AssertionAt: x.last.AssertionAt}
			}, func(_ context.Context, delay time.Duration) bool {
				delays = append(delays, delay)
				if _, authorized := s.registry.ProviderServingAuthorization(p); authorized || s.authorizer.Current(p) != nil {
					t.Fatal("an Apple error granted serving or retained unverified proof")
				}
				if s.registry.ProviderServingDenialReason(p) != "" {
					t.Fatal("an Apple API failure became a security denial")
				}
				return true
			}, observeFailure)
			if attempts != 4 || !reflect.DeepEqual(delays, []time.Duration{time.Minute, 5 * time.Minute, recovery.AssertionInterval}) {
				t.Fatalf("Apple error stopped recovery: attempts=%d delays=%v", attempts, delays)
			}
			if !reflect.DeepEqual(policies, []string{"unknown", "unknown", "unknown", "unknown"}) {
				t.Fatalf("infrastructure failure presented as known ineligibility: %v", policies)
			}
		})
	}
}

func TestAppleErrorRecoveryRequiresFreshQualifiedProof(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, _, state := newAuthorizationFixture(t)
		s.store = &statusReadinessStore{MemoryStore: memorystore.NewMemory(store.Config{}), state: state}
		h := &rotationHarness{mem: s.store.(*statusReadinessStore).MemoryStore}
		x := h.exchange(3, p)
		identity := identityForAuthorization(s, p, nil)
		attempts := 0
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		x.drive(ctx, func(_ context.Context, binding recovery.Binding) recovery.Outcome {
			attempts++
			if attempts == 1 {
				return recovery.Outcome{Reason: "apple_error"}
			}
			// The cryptographic exchange is covered separately. Here only the
			// normal verified-proof entry point may establish serving permission.
			e := s.evidence
			e.Binding.Connection, e.Expected.Connection = binding.Session, binding.Session
			e.AssertionAt = time.Now()
			eligibility.ApplyReadiness(&e, state)
			// The virtual minute also expires the build-policy snapshot. A
			// successful recovery must refresh it just as the live worker does.
			if err := s.RefreshBuildQualifications(ctx); err != nil {
				t.Fatal(err)
			}
			identity.Update(authorization.NewVerifiedProof(e, &s.status, binding.Session, nil, 0), appattest.EvaluateAuthorization(e, time.Now()))
			cancel()
			return recovery.Outcome{AssertionAt: e.AssertionAt}
		}, func(_ context.Context, delay time.Duration) bool {
			if _, authorized := s.registry.ProviderServingAuthorization(p); authorized {
				t.Fatal("retry scheduling authorized a provider without proof")
			}
			time.Sleep(delay)
			return true
		}, func(reason string) { s.authorizer.RejectProof(p, reason) })
		lease, authorized := s.registry.ProviderServingAuthorization(p)
		if attempts != 2 || !authorized || lease.IssuedAt != time.Now() {
			t.Fatalf("same-connection recovery failed: attempts=%d authorized=%v", attempts, authorized)
		}
	})
}
