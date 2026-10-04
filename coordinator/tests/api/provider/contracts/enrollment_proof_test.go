package provider_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/legacymdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/smallstep/pkcs7"
)

func TestEnrollmentRequiresBoundFreshMachineProof(t *testing.T) {
	ctx := context.Background()
	st := memory.NewMemory(store.Config{})
	newKey := func() (*ecdsa.PrivateKey, string) {
		t.Helper()
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		return key, base64.StdEncoding.EncodeToString(elliptic.Marshal(key.Curve, key.X, key.Y))
	}
	key, publicKey := newKey()
	otherKey, otherPublic := newKey()
	old := time.Now().Add(-time.Hour)
	if err := st.CreateUser(&store.User{AccountID: "old-account", PrivyUserID: "did:privy:old-account", CreatedAt: old}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ObserveMachine(ctx, store.MachineObservation{SessionID: "old-session", AccountID: "old-account", SEKey: publicKey, VerifiedSerial: "old-serial", At: old}); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertProvider(ctx, store.ProviderRecord{ID: "old-session", AccountID: "old-account", SEPublicKey: publicKey, SerialNumber: "old-serial", RegisteredAt: old}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.UpsertProviderTrustReuse(ctx, store.ProviderTrustReuse{
		SEPubKey: publicKey, Serial: "old-serial", TrustLevel: string(registry.TrustHardware),
		LastVerifiedBinaryHash: strings.Repeat("a", 64), SIPEnabled: true, SecureBootFull: true,
		MDAUDID: "old-udid", HardwareProofVerifiedAt: old, EvidenceGeneration: 1,
	}, 0); err != nil {
		t.Fatal(err)
	}
	for _, token := range []struct {
		raw, account string
		active       bool
	}{{"old-token", "old-account", true}, {"second-token", "old-account", true}, {"other-token", "new-account", true}, {"inactive-token", "old-account", false}} {
		hash := sha256.Sum256([]byte(token.raw))
		if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: fmt.Sprintf("%x", hash), AccountID: token.account, Active: token.active}); err != nil {
			t.Fatal(err)
		}
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := api.NewServer(registry.New(logger), st, api.ServerConfig{AppAttestShadow: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 100}}, logger)
	t.Cleanup(srv.Close)
	if err := srv.Trust().InitializeLegacyMDMPolicy(ctx); err != nil {
		t.Fatal(err)
	}
	srv.SetBaseURL("https://enrollment.example.test")
	srv.SetProfileSigner(newTestProfileSigner(t))
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	proof := func(token, pub string, at int64, signer *ecdsa.PrivateKey) legacymdm.EnrollmentProof {
		t.Helper()
		hash := sha256.Sum256([]byte(token))
		message := fmt.Sprintf("darkbloom-mdm-enroll-v1\n%x\n%s\n%d", hash, pub, at)
		digest := sha256.Sum256([]byte(message))
		sig, err := ecdsa.SignASN1(rand.Reader, signer, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		return legacymdm.EnrollmentProof{SEPublicKey: pub, Timestamp: at, Signature: base64.StdEncoding.EncodeToString(sig)}
	}
	now := time.Now().Unix()
	tamperedTimestampProof := proof("old-token", publicKey, now-1, key)
	tamperedTimestampProof.Timestamp = now
	for _, tc := range []struct {
		name, token string
		proof       legacymdm.EnrollmentProof
		want        int
	}{
		{"linked old machine", "old-token", proof("old-token", publicKey, now, key), 200},
		{"missing authentication", "", proof("old-token", publicKey, now, key), 401},
		{"unknown credential", "unknown-token", proof("unknown-token", publicKey, now, key), 401},
		{"wrong account", "other-token", proof("other-token", publicKey, now, key), 403},
		{"new key with copied serial", "old-token", proof("old-token", otherPublic, now, otherKey), 403},
		{"wrong signer", "old-token", proof("old-token", publicKey, now, otherKey), 403},
		{"different token same account", "second-token", proof("old-token", publicKey, now, key), 403},
		{"expired proof", "old-token", proof("old-token", publicKey, now-600, key), 403},
		{"future proof", "old-token", proof("old-token", publicKey, now+600, key), 403},
		{"timestamp changed after signing", "old-token", tamperedTimestampProof, 403},
		{"inactive credential", "inactive-token", proof("inactive-token", publicKey, now, key), 401},
		{"missing proof", "old-token", legacymdm.EnrollmentProof{}, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, err := json.Marshal(map[string]any{"se_public_key": tc.proof.SEPublicKey, "timestamp": tc.proof.Timestamp, "signature": tc.proof.Signature, "serial_number": "old-serial"})
			if err != nil {
				t.Fatal(err)
			}
			req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/enroll", bytes.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Content-Type", "application/json")
			if tc.token != "" {
				req.Header.Set("Authorization", "Bearer "+tc.token)
			}
			resp, err := ts.Client().Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			responseBody, err := io.ReadAll(resp.Body)
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != tc.want {
				t.Fatalf("status=%d, want %d: %s", resp.StatusCode, tc.want, responseBody)
			}
			if tc.want != http.StatusOK {
				if bytes.Contains(responseBody, []byte("com.apple.mdm")) || resp.Header.Get("Content-Disposition") != "" {
					t.Fatal("denied request received an enrollment profile")
				}
				return
			}
			if resp.Header.Get("Content-Type") != "application/x-apple-aspen-config" || resp.Header.Get("Content-Disposition") != `attachment; filename="Darkbloom-Enroll.mobileconfig"` {
				t.Fatal("authorized enrollment lost its download headers")
			}
			p7, err := pkcs7.Parse(responseBody)
			if err != nil {
				t.Fatalf("authorized enrollment did not receive CMS-signed profile: %v", err)
			}
			if !bytes.Contains(p7.Content, []byte("com.apple.mdm")) || !bytes.Contains(p7.Content, []byte("https://enrollment.example.test/scep")) || bytes.Contains(p7.Content, []byte("old-serial")) {
				t.Fatal("signed profile lost canonical endpoints or exposed device identity")
			}
		})
	}
}
