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
)

func TestEnrollmentExpiryCanRecoverWithoutRetryingBindingViolations(t *testing.T) {
	for _, scenario := range []string{"expired", "wrong owner", "wrong key", "wrong app", "wrong account", "wrong environment", "future"} {
		t.Run(scenario, func(t *testing.T) {
			st := store.NewMemory(store.Config{})
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
