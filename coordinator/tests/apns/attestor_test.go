package apns_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

// testP8 generates a throwaway ECDSA P-256 key as a PKCS#8 PEM (a fake .p8).
func testP8(t *testing.T) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal pkcs8: %v", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func newTestAttestor(t *testing.T, cfg production.Config) *production.APNsPushAttestor {
	t.Helper()
	if cfg.TeamID == "" {
		cfg.TeamID = "P7373SVQX6"
	}
	if cfg.KeyID == "" {
		cfg.KeyID = "HRP6NBC5HC"
	}
	if cfg.Topic == "" {
		cfg.Topic = "io.darkbloom.provider"
	}
	if cfg.AuthKeyPEM == nil {
		cfg.AuthKeyPEM = testP8(t)
	}
	a, err := production.NewAPNsPushAttestor(cfg)
	if err != nil {
		t.Fatalf("NewAPNsPushAttestor: %v", err)
	}
	return a
}

// The provider decrypts code_challenge exactly as it decrypts an inference body.
// This proves the coordinator's E_K(nonce) round-trips to the provider's K.
func TestBuildCodeChallengePayloadRoundTrip(t *testing.T) {
	provider, err := e2e.GenerateSessionKeys() // stand-in for the provider's K
	if err != nil {
		t.Fatalf("gen provider keys: %v", err)
	}
	providerPubB64 := base64.StdEncoding.EncodeToString(provider.PublicKey[:])
	nonceB64 := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))

	for _, mode := range []production.Mode{production.ModeBackground, production.ModeAlert} {
		payload, err := production.BuildCodeChallengePayload(nonceB64, providerPubB64, mode)
		if err != nil {
			t.Fatalf("BuildCodeChallengePayload(%s): %v", mode, err)
		}
		var body struct {
			Aps           map[string]any       `json:"aps"`
			CodeChallenge e2e.EncryptedPayload `json:"code_challenge"`
		}
		if err := json.Unmarshal(payload, &body); err != nil {
			t.Fatalf("unmarshal payload: %v", err)
		}
		if body.Aps["content-available"] != float64(1) {
			t.Errorf("%s: content-available not set: %v", mode, body.Aps)
		}
		if mode == production.ModeAlert && body.Aps["alert"] == nil {
			t.Errorf("alert mode must include an alert dict: %v", body.Aps)
		}
		if mode == production.ModeBackground && body.Aps["alert"] != nil {
			t.Errorf("background mode must NOT include an alert dict: %v", body.Aps)
		}
		// Provider-side decrypt with K's private key.
		recovered, err := e2e.DecryptWithPrivateKey(&body.CodeChallenge, provider.PrivateKey)
		if err != nil {
			t.Fatalf("%s: provider decrypt failed: %v", mode, err)
		}
		if string(recovered) != nonceB64 {
			t.Errorf("%s: decrypted nonce mismatch: got %q want %q", mode, recovered, nonceB64)
		}
	}
}

func TestJWTMintAndCache(t *testing.T) {
	base := time.Unix(1_780_000_000, 0)
	now := base
	tokens := make(chan string, 1)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tokens <- strings.TrimPrefix(r.Header.Get("authorization"), "bearer ")
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()
	a := newTestAttestor(t, production.Config{
		HostOverride: ts.URL,
		HTTPClient:   ts.Client(),
		Now:          func() time.Time { return now },
	})
	provider, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	providerPubB64 := base64.StdEncoding.EncodeToString(provider.PublicKey[:])
	jwt := func() string {
		t.Helper()
		if err := a.SendCodeChallenge(context.Background(), "tok", "production", providerPubB64, "nonce"); err != nil {
			t.Fatalf("jwt: %v", err)
		}
		return <-tokens
	}
	tok1 := jwt()
	parts := strings.Split(tok1, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt must have 3 parts, got %d", len(parts))
	}
	hdr, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("decode header: %v", err)
	}
	var h map[string]string
	if err := json.Unmarshal(hdr, &h); err != nil {
		t.Fatalf("unmarshal header: %v", err)
	}
	if h["alg"] != "ES256" || h["kid"] != "HRP6NBC5HC" {
		t.Errorf("header alg/kid wrong: %v", h)
	}

	// Cached within jwtMaxAge.
	tok2 := jwt()
	if tok2 != tok1 {
		t.Error("jwt should be cached (reused) within jwtMaxAge to avoid TooManyProviderTokenUpdates")
	}
	// Refreshed after jwtMaxAge.
	now = base.Add(51 * time.Minute)
	tok3 := jwt()
	if tok3 == tok1 {
		t.Error("jwt should refresh after jwtMaxAge")
	}
}

func TestSendCodeChallengeHeadersAndPayload(t *testing.T) {
	provider, _ := e2e.GenerateSessionKeys()
	providerPubB64 := base64.StdEncoding.EncodeToString(provider.PublicKey[:])
	nonceB64 := base64.StdEncoding.EncodeToString([]byte("nonce-nonce-nonce-nonce-nonce-32"))

	type capture struct {
		method, path, topic, pushType, priority, auth, expiration string
		body                                                      []byte
	}
	cases := []struct {
		mode         production.Mode
		wantPushType string
		wantPriority string
		wantAlert    bool
	}{
		{production.ModeBackground, "background", "5", false},
		{production.ModeAlert, "alert", "10", true},
	}
	for _, tc := range cases {
		var got capture
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			got.method = r.Method
			got.path = r.URL.Path
			got.topic = r.Header.Get("apns-topic")
			got.pushType = r.Header.Get("apns-push-type")
			got.priority = r.Header.Get("apns-priority")
			got.auth = r.Header.Get("authorization")
			got.expiration = r.Header.Get("apns-expiration")
			got.body, _ = readAll(r)
			w.WriteHeader(http.StatusOK)
		}))
		a := newTestAttestor(t, production.Config{Mode: tc.mode, HostOverride: ts.URL, HTTPClient: ts.Client()})
		err := a.SendCodeChallenge(context.Background(), "abc123token", "production", providerPubB64, nonceB64)
		ts.Close()
		if err != nil {
			t.Fatalf("%s: SendCodeChallenge: %v", tc.mode, err)
		}
		if got.method != http.MethodPost || got.path != "/3/device/abc123token" {
			t.Errorf("%s: method/path = %s %s", tc.mode, got.method, got.path)
		}
		if got.topic != "io.darkbloom.provider" {
			t.Errorf("%s: topic = %q", tc.mode, got.topic)
		}
		if got.pushType != tc.wantPushType || got.priority != tc.wantPriority {
			t.Errorf("%s: push-type/priority = %q/%q want %q/%q", tc.mode, got.pushType, got.priority, tc.wantPushType, tc.wantPriority)
		}
		if !strings.HasPrefix(got.auth, "bearer ") {
			t.Errorf("%s: authorization = %q", tc.mode, got.auth)
		}
		if got.expiration == "" {
			t.Errorf("%s: apns-expiration missing", tc.mode)
		}
		var body struct {
			Aps map[string]any `json:"aps"`
		}
		if err := json.Unmarshal(got.body, &body); err != nil {
			t.Fatalf("%s: body not JSON: %v", tc.mode, err)
		}
		if (body.Aps["alert"] != nil) != tc.wantAlert {
			t.Errorf("%s: alert presence = %v want %v", tc.mode, body.Aps["alert"] != nil, tc.wantAlert)
		}
	}
}

func TestSendCodeChallenge429Backoff(t *testing.T) {
	provider, _ := e2e.GenerateSessionKeys()
	providerPubB64 := base64.StdEncoding.EncodeToString(provider.PublicKey[:])
	nonceB64 := base64.StdEncoding.EncodeToString([]byte("nonce-nonce-nonce-nonce-nonce-32"))

	var hits int
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Retry-After", "120")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"reason":"TooManyRequests"}`))
	}))
	defer ts.Close()
	base := time.Unix(1_780_000_000, 0)
	now := base
	a := newTestAttestor(t, production.Config{
		HostOverride: ts.URL,
		HTTPClient:   ts.Client(),
		Now:          func() time.Time { return now },
	})

	if err := a.SendCodeChallenge(context.Background(), "tok", "production", providerPubB64, nonceB64); err == nil {
		t.Fatal("expected 429 error")
	}
	if hits != 1 {
		t.Fatalf("expected 1 hit, got %d", hits)
	}
	// Second send within the backoff window must not hit the server.
	if err := a.SendCodeChallenge(context.Background(), "tok", "production", providerPubB64, nonceB64); err == nil {
		t.Fatal("expected backoff error")
	}
	if hits != 1 {
		t.Errorf("backoff should have prevented a 2nd request, hits=%d", hits)
	}
	// After the backoff window, it sends again.
	now = base.Add(3 * time.Minute)
	_ = a.SendCodeChallenge(context.Background(), "tok", "production", providerPubB64, nonceB64)
	if hits != 2 {
		t.Errorf("expected request after backoff expiry, hits=%d", hits)
	}
}

func readAll(r *http.Request) ([]byte, error) {
	defer r.Body.Close()
	buf := make([]byte, 0, 1024)
	tmp := make([]byte, 1024)
	for {
		n, err := r.Body.Read(tmp)
		buf = append(buf, tmp[:n]...)
		if err != nil {
			return buf, nil
		}
	}
}
