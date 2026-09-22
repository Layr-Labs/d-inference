package service

import (
	"context"
	"reflect"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppleErrorRetriesExchangeWithBoundedBackoff(t *testing.T) {
	for _, phase := range []string{"ready", "attestation", "assertion"} {
		t.Run(phase, func(t *testing.T) {
			s, p, record, _ := newAuthorizationFixture(t)
			x := sessionForAuthorization(s, p, record)
			x.store, _ = store.As[store.AppAttestShadowStore](s.store)
			var policies []string
			s.emitEvent = func(fields map[string]any) {
				if fields["stage"] == "prospective_policy" {
					policies = append(policies, fields["outcome"].(string))
				}
			}
			attempts := 0
			previous := x.id
			var delays []time.Duration
			x.runRecovering(context.Background(), func(ctx context.Context) {
				attempts++
				if attempts > 1 {
					if x.id == previous || x.key != nil || x.challenge != "" || x.expected != "" {
						t.Fatal("retry reused the failed exchange or cached acceptance")
					}
					previous = x.id
				}
				x.expected, x.challenge = phase, "fresh-challenge"
				result := "apple_error"
				if attempts == 4 {
					result = "unsupported" // A permanent response still ends retries.
				}
				if next := x.handle(ctx, protocol.AppAttestShadowPayload{
					Session: x.id, Action: phase, Result: result,
				}); next != "stop" || x.lastOutcome != result {
					t.Fatalf("exchange next=%s outcome=%s", next, x.lastOutcome)
				}
			}, func(_ context.Context, delay time.Duration) bool {
				delays = append(delays, delay)
				if _, authorized := s.registry.ProviderServingAuthorization(p); authorized || s.authorizer.current[p] != nil {
					t.Fatal("an Apple error granted serving or retained unverified proof")
				}
				if s.registry.ProviderServingDenialReason(p) != "" {
					t.Fatal("an Apple API failure became a security denial")
				}
				return true
			})
			if attempts != 4 || !reflect.DeepEqual(delays, []time.Duration{time.Minute, 5 * time.Minute, time.Hour}) {
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
		s, p, record, state := newAuthorizationFixture(t)
		s.store = &statusReadinessStore{MemoryStore: store.NewMemory(store.Config{}), state: state}
		x := sessionForAuthorization(s, p, record)
		attempts := 0
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		x.runRecovering(ctx, func(context.Context) {
			attempts++
			if attempts == 1 {
				x.lastOutcome = "apple_error"
				return
			}
			// The cryptographic exchange is covered separately. Here only the
			// normal verified-proof entry point may establish serving permission.
			e := record.evidence
			e.Binding.Connection, e.Expected.Connection = x.id, x.id
			e.AssertionAt = time.Now()
			applyAppAttestReadiness(&e, state)
			x.key = &store.AppAttestShadowKey{KeyID: e.Binding.Credential}
			// The virtual minute also expires the build-policy snapshot. A
			// successful recovery must refresh it just as the live worker does.
			if err := s.RefreshBuildQualifications(ctx); err != nil {
				t.Fatal(err)
			}
			x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
			cancel()
		}, func(_ context.Context, delay time.Duration) bool {
			if _, authorized := s.registry.ProviderServingAuthorization(p); authorized {
				t.Fatal("retry scheduling authorized a provider without proof")
			}
			time.Sleep(delay)
			return true
		})
		lease, authorized := s.registry.ProviderServingAuthorization(p)
		if attempts != 2 || !authorized || lease.IssuedAt != time.Now() {
			t.Fatalf("same-connection recovery failed: attempts=%d authorized=%v", attempts, authorized)
		}
	})
}
