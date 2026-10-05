package exchange_test

import (
	"context"
	"encoding/base64"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func enrollmentExchange(st *memorystore.MemoryStore) (*exchange.Pipeline, exchange.Attempt, *storagebudget.Scope) {
	budget, integrity := &storagebudget.Budget{}, &evidence.Integrity{}
	scope := storagebudget.NewScope(budget)
	credential := &store.AppAttestShadowKey{KeyID: "key"}
	x := exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{AppID: "TEST.app", Environment: "production", Session: "current", Owner: "owner", Account: "account",
		PublicKey: "endpoint", Challenge: "nonce", ProtocolVersion: 3, KeyID: &credential.KeyID}, Expected: "attestation", Credential: credential}}
	pipeline := exchange.NewPipeline(exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: st}, Archive: st, Enrollments: st, Provider: &registry.Provider{ID: "connection"},
		Budget: budget, Scope: scope, Integrity: integrity})
	return pipeline, x, scope
}

func TestEnrollmentExpiryCanRecoverWithoutRetryingBindingViolations(t *testing.T) {
	for _, scenario := range []string{"expired", "wrong owner", "wrong key", "wrong app", "wrong account", "wrong environment", "future"} {
		t.Run(scenario, func(t *testing.T) {
			st := memorystore.NewMemory(store.Config{})
			pipeline, x, _ := enrollmentExchange(st)
			// The server saved its context before the Apple call. A proof cached
			// 25 seconds later can still be within the client's 24h TTL while the
			// server transaction has expired. Neither timestamp may be extended.
			e := store.AppAttestEnrollment{ProtocolVersion: 3, ID: "original", Owner: x.Challenge.Binding.Owner, KeyID: "key", CreatedAt: time.Now().Add(-24*time.Hour - time.Second), AppID: "TEST.app", Environment: "production", Challenge: "original nonce", PublicKey: "original endpoint", AccountScope: transcript.AccountScope(x.Challenge.Binding.Account)}
			expected := "enrollment_context"
			switch scenario {
			case "expired":
				expected = "enrollment_expired"
			case "wrong owner":
				e.Owner = "another owner"
			case "wrong key":
				e.KeyID = "another key"
			case "wrong app":
				e.AppID = "OTHER.app"
			case "wrong account":
				e.AccountScope = "another account"
			case "wrong environment":
				e.Environment = "development"
			case "future":
				e.CreatedAt = time.Now().Add(time.Hour)
			}
			if err := st.SaveAppAttestEnrollment(context.Background(), e); err != nil {
				t.Fatal(err)
			}
			reply := protocol.AppAttestShadowPayload{Action: "attestation", Result: "ok", Session: x.Challenge.Binding.Session, Challenge: x.Challenge.Binding.Challenge, KeyID: "key", ProtocolVersion: 3, EnrollmentSession: e.ID, Status: &protocol.AppAttestStatus{OSVersion: "27"}, Proof: base64.StdEncoding.EncodeToString([]byte{1})}
			result := pipeline.Handle(context.Background(), x, reply)
			if next := result.Next; next != "stop" || result.Outcome != expected {
				t.Fatalf("expiry/binding classification: next=%s outcome=%s want=%s", next, result.Outcome, expected)
			}
			if recovery.RetryableOutcome(result.Outcome) != (scenario == "expired") {
				t.Fatal("expiry recovery lost or binding violation became retryable")
			}
			key, err := st.GetAppAttestShadowKey(context.Background(), "key")
			if err != nil || key != nil {
				t.Fatal("stale proof accepted a credential", err)
			}
		})
	}
}

// Stored enrollments without a protocol version, or from protocol 2, can no
// longer be resumed. One still inside the 24h window is refused as a binding
// violation that is not retried (no loop on the old proof); an older one keeps
// the retryable expiry outcome. Either way nothing is accepted, and the same
// connection can start a fresh protocol-3 enrollment on its own session.
func TestPreV3EnrollmentIsRefusedAndFreshV3EnrollmentStarts(t *testing.T) {
	for _, tc := range []struct {
		name    string
		version int
		age     time.Duration
		want    string
	}{
		{"no version, recent", 0, time.Hour, "enrollment_context"},
		{"protocol 2, recent", 2, time.Hour, "enrollment_context"},
		{"no version, expired", 0, 24*time.Hour + time.Second, "enrollment_expired"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			st := memorystore.NewMemory(store.Config{})
			pipeline, x, scope := enrollmentExchange(st)
			stale := store.AppAttestEnrollment{ProtocolVersion: tc.version, ID: "stale", Owner: x.Challenge.Binding.Owner, KeyID: "key", CreatedAt: time.Now().Add(-tc.age), AppID: "TEST.app", Environment: "production", Challenge: "stale nonce", PublicKey: "stale endpoint", AccountScope: transcript.AccountScope(x.Challenge.Binding.Account)}
			if err := st.SaveAppAttestEnrollment(ctx, stale); err != nil {
				t.Fatal(err)
			}
			reply := protocol.AppAttestShadowPayload{Action: "attestation", Result: "ok", Session: x.Challenge.Binding.Session, Challenge: x.Challenge.Binding.Challenge, KeyID: "key", ProtocolVersion: 3, EnrollmentSession: stale.ID, Status: &protocol.AppAttestStatus{OSVersion: "27"}, Proof: base64.StdEncoding.EncodeToString([]byte{1})}
			result := pipeline.Handle(ctx, x, reply)
			if next := result.Next; next != "stop" || result.Outcome != tc.want {
				t.Fatalf("stale enrollment: next=%s outcome=%s want=%s", next, result.Outcome, tc.want)
			}
			if recovery.RetryableOutcome(result.Outcome) != (tc.want == "enrollment_expired") {
				t.Fatalf("outcome %s has the wrong retry class", result.Outcome)
			}
			if key, err := st.GetAppAttestShadowKey(ctx, "key"); err != nil || key != nil {
				t.Fatal("stale enrollment accepted a credential", err)
			}

			// A fresh attest on this connection records a protocol-3
			// enrollment and signs the current session's transcript.
			sent := exchange.Send(ctx, exchange.SendDependencies{Enrollments: st, Scope: scope, Transport: (&registry.Provider{ID: "connection"}).EnqueueText}, x.Challenge.Binding, x.Challenge.Credential, "attest")
			x.Challenge.Binding.Challenge = sent.Challenge
			if sent.Sent {
				t.Fatal("send reached a provider without a writer")
			}
			fresh, err := st.GetAppAttestEnrollment(ctx, x.Challenge.Binding.Session)
			if err != nil || fresh == nil || fresh.ProtocolVersion != 3 || fresh.Challenge != x.Challenge.Binding.Challenge {
				t.Fatalf("fresh enrollment = %+v, %v; want protocol 3 on the current challenge", fresh, err)
			}
			reply.EnrollmentSession = ""
			hash, _, err := transcript.Prepare(ctx, st, x.Challenge.Binding, "attest", reply)
			if err != nil || hash != protocol.AppAttestShadowHashV3("attest", x.Challenge.Binding.Session, "production", "key", x.Challenge.Binding.Challenge, x.Challenge.Binding.PublicKey, transcript.AccountScope(x.Challenge.Binding.Account), reply.Status) {
				t.Fatal("fresh enrollment did not use the protocol-3 transcript", err)
			}
		})
	}
}
