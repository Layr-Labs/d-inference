package trust_test

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

func seedLegacyMDMRegistration(t *testing.T, st *memory.MemoryStore, key, serial string) {
	t.Helper()
	ctx := context.Background()
	old := time.Now().Add(-time.Hour)
	if err := st.CreateUser(&store.User{AccountID: "old-account", PrivyUserID: "did:privy:old-account", CreatedAt: old}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ObserveMachine(ctx, store.MachineObservation{SessionID: "historical-session", AccountID: "old-account", SEKey: key, VerifiedSerial: serial, At: old}); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertProvider(ctx, store.ProviderRecord{
		ID: "historical-session", AccountID: "old-account", SEPublicKey: key,
		SerialNumber: serial, RegisteredAt: old, TrustLevel: string(registry.TrustSelfSigned), FailedChallenges: 9,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.UpsertProviderTrustReuse(ctx, hardwareReuseRecord(key, serial, trHashA, old), 0); err != nil {
		t.Fatal(err)
	}
}

func newLegacyMDMRegistrationServer(t *testing.T, st store.Store, reg *registry.Registry) *api.Server {
	t.Helper()
	srv := api.NewServer(reg, st, api.ServerConfig{AppAttestShadow: api.AppAttestShadowConfig{
		ServingEnabled: true, Environment: "production", RolloutPercent: 100,
	}}, quietLogger())
	t.Cleanup(srv.Close)
	if err := srv.Trust().InitializeLegacyMDMPolicy(context.Background()); err != nil {
		t.Fatal(err)
	}
	return srv
}

type registrationTokenFailureStore struct {
	store.Store
	reads atomic.Int32
}

func (s *registrationTokenFailureStore) Unwrap() store.Store { return s.Store }

func (s *registrationTokenFailureStore) GetProviderToken(token string) (*store.ProviderToken, error) {
	if s.reads.Add(1) == 1 {
		return nil, errors.New("private token lookup failure: " + token)
	}
	return s.Store.GetProviderToken(token)
}

func TestLegacyMDMIdentityCandidateCannotFallBackForNewIdentity(t *testing.T) {
	for _, tc := range []struct {
		name, account, os string
		protocol          int
		oldPair           bool
		want              bool
	}{
		{"old pair unsupported App Attest", "old-account", "26.0", 0, true, false},
		{"new key copied serial", "old-account", "27.0", 3, false, true},
		{"new account old key", "new-account", "27.0", 3, true, true},
		{"new machine old OS", "old-account", "26.0", 3, false, true},
		{"new machine unsupported protocol", "old-account", "27.0", 0, false, true},
		{"unlinked old key", "", "26.0", 0, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := memory.NewMemory(store.Config{})
			reg := registry.New(quietLogger())
			oldAttestation := buildTestAttestationJSONWithFields(t, testPublicKeyB64(), "", "copied-serial", time.Now(), map[string]interface{}{"osVersion": tc.os})
			oldResult, err := attestation.VerifyJSON(oldAttestation)
			if err != nil || !oldResult.Valid {
				t.Fatalf("invalid fixture: result=%+v error=%v", oldResult, err)
			}
			seedLegacyMDMRegistration(t, st, oldResult.PublicKey, "copied-serial")
			srv := newLegacyMDMRegistrationServer(t, st, reg)
			registration := &protocol.RegisterMessage{AppAttestProtocol: tc.protocol, Attestation: oldAttestation}
			if !tc.oldPair {
				registration.Attestation = buildTestAttestationJSONWithFields(t, testPublicKeyB64(), "", "copied-serial", time.Now(), map[string]interface{}{"osVersion": tc.os})
			}
			if got := srv.Trust().AppAttestIdentityCandidate(registration, tc.account); got != tc.want {
				t.Fatalf("identity candidate=%t, want %t", got, tc.want)
			}
			if !srv.Trust().AppAttestIdentityCandidate(nil, tc.account) || !srv.Trust().AppAttestIdentityCandidate(&protocol.RegisterMessage{Attestation: json.RawMessage(`{}`)}, tc.account) {
				t.Fatal("missing verified identity retained serial-based legacy recovery")
			}
			duplicate := reg.Register("duplicate", nil, &protocol.RegisterMessage{})
			duplicate.SetAttestationResult(&oldResult)
			p := reg.Register("current", nil, registration)
			if tc.want {
				p.RequireVerifiedMachineIdentity()
			}
			if err := srv.Trust().VerifyProviderAttestation(context.Background(), p.ID, p, registration, tc.account); err != nil {
				t.Fatal(err)
			}
			p.Mu().Lock()
			failures, restoredAccount := p.FailedChallenges, p.AccountID
			p.Mu().Unlock()
			if tc.want {
				if reg.GetProvider("duplicate") == nil || failures != 0 || restoredAccount != "" {
					t.Fatalf("new identity used legacy serial recovery: failures=%d account=%q duplicate=%t", failures, restoredAccount, reg.GetProvider("duplicate") != nil)
				}
			} else if reg.GetProvider("duplicate") != nil || failures != 9 || restoredAccount != "old-account" {
				t.Fatalf("old identity lost legacy recovery: failures=%d account=%q duplicate=%t", failures, restoredAccount, reg.GetProvider("duplicate") != nil)
			}
		})
	}
}

func TestLegacyMDMWebSocketRegistrationRequiresAppAttestForOwnerServing(t *testing.T) {
	for _, tc := range []struct {
		name, account, token, os  string
		protocol                  int
		oldKey, active, wantOwner bool
	}{
		{"grandfathered old OS and protocol", "old-account", "linked-token", "26.0", 0, true, true, true},
		{"new key copied serial old OS and protocol", "old-account", "linked-token", "26.0", 0, false, true, false},
		{"new key unsupported OS", "old-account", "linked-token", "26.0", 3, false, true, false},
		{"new key unsupported protocol", "old-account", "linked-token", "27.0", 0, false, true, false},
		{"new account old key", "new-account", "linked-token", "27.0", 3, true, true, false},
		{"invalid token old key", "", "invalid-token", "26.0", 0, true, false, false},
		{"inactive token old key", "", "linked-token", "26.0", 0, true, false, false},
		{"absent token old key", "", "", "26.0", 0, true, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := memory.NewMemory(store.Config{})
			reg := registry.New(quietLogger())
			key := testPublicKeyB64()
			oldAttestation := buildTestAttestationJSONWithFields(t, key, "", "SERIAL-1", time.Now(), map[string]interface{}{"osVersion": tc.os})
			oldResult, err := attestation.VerifyJSON(oldAttestation)
			if err != nil || !oldResult.Valid {
				t.Fatalf("invalid fixture: result=%+v error=%v", oldResult, err)
			}
			seedLegacyMDMRegistration(t, st, oldResult.PublicKey, "SERIAL-1")
			tokenAccount := tc.account
			if tokenAccount == "" {
				tokenAccount = "old-account"
			}
			tokenHash := sha256.Sum256([]byte("linked-token"))
			if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: fmt.Sprintf("%x", tokenHash), AccountID: tokenAccount, Active: tc.active}); err != nil {
				t.Fatal(err)
			}
			failing := &registrationTokenFailureStore{Store: st}
			srv := newLegacyMDMRegistrationServer(t, failing, reg)
			srv.SetSkipChallenge(true)
			signed := oldAttestation
			if !tc.oldKey {
				signed = buildTestAttestationJSONWithFields(t, key, "", "SERIAL-1", time.Now(), map[string]interface{}{"osVersion": tc.os})
			}
			server := httptest.NewServer(srv.Handler())
			t.Cleanup(server.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/ws/provider", nil)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "done") })
			registration := protocol.RegisterMessage{
				Type: protocol.TypeRegister, Version: api.LatestProviderVersion, Backend: "mlx-swift", PublicKey: key,
				AuthToken: tc.token, Attestation: signed, AppAttestProtocol: tc.protocol,
				EncryptedResponseChunks: true, PrivacyCapabilities: testPrivacyCaps(),
			}
			body, err := json.Marshal(registration)
			if err != nil {
				t.Fatal(err)
			}
			if err := conn.Write(ctx, websocket.MessageText, body); err != nil {
				t.Fatal(err)
			}
			if tc.token != "" {
				_, _, err := conn.Read(ctx)
				if websocket.CloseStatus(err) != websocket.StatusTryAgainLater || strings.Contains(err.Error(), tc.token) || strings.Contains(err.Error(), "private token lookup") {
					t.Fatalf("transient token lookup did not close safely for retry: %v", err)
				}
				if ids := reg.ProviderIDs(); len(ids) != 0 {
					t.Fatalf("transient token lookup registered providers before account classification: %v", ids)
				}
				if failing.reads.Load() != 1 {
					t.Fatal("failed connection retried token lookup")
				}
				records, err := st.ListProvidersByAccount(ctx, "old-account")
				if err != nil || len(records) != 1 || records[0].ID != "historical-session" {
					t.Fatalf("failed registration changed persisted providers: %+v, %v", records, err)
				}
				conn, _, err = websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/ws/provider", nil)
				if err != nil {
					t.Fatal(err)
				}
				if err := conn.Write(ctx, websocket.MessageText, body); err != nil {
					t.Fatal(err)
				}
			}
			// desired_models follows runtime reconciliation; readiness set below cannot be overwritten by registration.
			for {
				_, data, err := conn.Read(ctx)
				if err != nil {
					t.Fatal(err)
				}
				var envelope struct {
					Type string `json:"type"`
				}
				if err := json.Unmarshal(data, &envelope); err != nil {
					t.Fatal(err)
				}
				if envelope.Type == protocol.TypeDesiredModels {
					break
				}
			}
			ids := reg.ProviderIDs()
			if tc.token != "" && failing.reads.Load() != 2 {
				t.Fatal("reconnected registration must resolve token exactly once")
			}
			if len(ids) != 1 {
				t.Fatalf("registered provider count=%d, want 1", len(ids))
			}
			provider := reg.GetProvider(ids[0])
			if provider == nil {
				t.Fatal("WebSocket provider disconnected after registration")
			}
			provider.Mu().Lock()
			linkedAccount := provider.AccountID
			// Satisfy independent runtime/challenge gates, leaving the real onboarding authorization decision intact.
			provider.TrustLevel = registry.TrustSelfSigned
			provider.RuntimeVerified = true
			provider.RuntimeManifestChecked = true
			provider.ChallengeVerifiedSIP = true
			provider.LastChallengeVerified = time.Now()
			provider.CodeAttested = true
			provider.Mu().Unlock()
			if linkedAccount != tc.account {
				t.Fatalf("linked account=%q, want %q; invalid or absent credentials must clear restored linkage", linkedAccount, tc.account)
			}
			if got := reg.ProviderOwnerServingAuthorized(provider); got != tc.wantOwner {
				t.Fatalf("owner serving authorization=%t, want %t without App Attest", got, tc.wantOwner)
			}
		})
	}
}
