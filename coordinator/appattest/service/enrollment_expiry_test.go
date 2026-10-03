package service

import (
	"context"
	"encoding/base64"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestEnrollmentExpiryCanRecoverWithoutRetryingBindingViolations(t *testing.T) {
	for _, scenario := range []string{"expired", "wrong owner", "wrong key", "wrong app", "wrong account", "wrong environment", "future"} {
		t.Run(scenario, func(t *testing.T) {
			st := memorystore.NewMemory(store.Config{})
			x := &Session{s: &Service{store: st, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), config: Config{AppID: "TEST.app", Environment: "production"}}, store: st, provider: &registry.Provider{ID: "connection"}, id: "current", owner: "owner", account: "account", publicKey: "endpoint", challenge: "nonce", expected: "attestation", protocolVersion: 3, key: &store.AppAttestShadowKey{KeyID: "key"}}
			// The server saved its context before the Apple call. A proof cached
			// 25 seconds later can still be within the client's 24h TTL while the
			// server transaction has expired. Neither timestamp may be extended.
			e := store.AppAttestEnrollment{ProtocolVersion: 3, ID: "original", Owner: x.owner, KeyID: "key", CreatedAt: time.Now().Add(-24*time.Hour - time.Second), AppID: "TEST.app", Environment: "production", Challenge: "original nonce", PublicKey: "original endpoint", AccountScope: x.accountScope()}
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
			reply := protocol.AppAttestShadowPayload{Action: "attestation", Result: "ok", Session: x.id, Challenge: x.challenge, KeyID: "key", ProtocolVersion: 3, EnrollmentSession: e.ID, Status: &protocol.AppAttestStatus{OSVersion: "27"}, Proof: base64.StdEncoding.EncodeToString([]byte{1})}
			if next := x.handle(context.Background(), reply); next != "stop" || x.lastOutcome != expected {
				t.Fatalf("expiry/binding classification: next=%s outcome=%s want=%s", next, x.lastOutcome, expected)
			}
			if retryableAppAttestOutcome(x.lastOutcome) != (scenario == "expired") {
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
			x := &Session{s: &Service{store: st, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), config: Config{AppID: "TEST.app", Environment: "production"}}, store: st, provider: &registry.Provider{ID: "connection"}, id: "current", owner: "owner", account: "account", publicKey: "endpoint", challenge: "nonce", expected: "attestation", protocolVersion: 3, key: &store.AppAttestShadowKey{KeyID: "key"}}
			stale := store.AppAttestEnrollment{ProtocolVersion: tc.version, ID: "stale", Owner: x.owner, KeyID: "key", CreatedAt: time.Now().Add(-tc.age), AppID: "TEST.app", Environment: "production", Challenge: "stale nonce", PublicKey: "stale endpoint", AccountScope: x.accountScope()}
			if err := st.SaveAppAttestEnrollment(ctx, stale); err != nil {
				t.Fatal(err)
			}
			reply := protocol.AppAttestShadowPayload{Action: "attestation", Result: "ok", Session: x.id, Challenge: x.challenge, KeyID: "key", ProtocolVersion: 3, EnrollmentSession: stale.ID, Status: &protocol.AppAttestStatus{OSVersion: "27"}, Proof: base64.StdEncoding.EncodeToString([]byte{1})}
			if next := x.handle(ctx, reply); next != "stop" || x.lastOutcome != tc.want {
				t.Fatalf("stale enrollment: next=%s outcome=%s want=%s", next, x.lastOutcome, tc.want)
			}
			if retryableAppAttestOutcome(x.lastOutcome) != (tc.want == "enrollment_expired") {
				t.Fatalf("outcome %s has the wrong retry class", x.lastOutcome)
			}
			if key, err := st.GetAppAttestShadowKey(ctx, "key"); err != nil || key != nil {
				t.Fatal("stale enrollment accepted a credential", err)
			}

			// A fresh attest on this connection records a protocol-3
			// enrollment and signs the current session's transcript.
			if x.send(ctx, "attest") {
				t.Fatal("send reached a provider without a writer")
			}
			fresh, err := st.GetAppAttestEnrollment(ctx, x.id)
			if err != nil || fresh == nil || fresh.ProtocolVersion != 3 || fresh.Challenge != x.challenge {
				t.Fatalf("fresh enrollment = %+v, %v; want protocol 3 on the current challenge", fresh, err)
			}
			reply.EnrollmentSession = ""
			hash, err := x.clientHash(ctx, "attest", reply)
			if err != nil || hash != protocol.AppAttestShadowHashV3("attest", x.id, "production", "key", x.challenge, x.publicKey, x.accountScope(), reply.Status) {
				t.Fatal("fresh enrollment did not use the protocol-3 transcript", err)
			}
		})
	}
}
