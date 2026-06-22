package auth

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/golang-jwt/jwt/v5"
)

const testAppID = "test-app-id"

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func testMemStore() store.Store {
	return store.NewMemory(store.Config{AdminKey: "test-key"})
}

// genES256Key returns a fresh ECDSA P-256 private key and the PKIX PEM encoding
// of its public key, exactly as the Privy dashboard hands an app its
// verification key.
func genES256Key(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatalf("marshal PKIX: %v", err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
	return priv, string(pemBytes)
}

func newAuth(t *testing.T, keyPEM, appSecret string, st store.Store) *PrivyAuth {
	t.Helper()
	a, err := NewPrivyAuth(Config{AppID: testAppID, AppSecret: appSecret, VerificationKey: keyPEM}, st, testLogger())
	if err != nil {
		t.Fatalf("NewPrivyAuth: %v", err)
	}
	return a
}

func signToken(t *testing.T, priv *ecdsa.PrivateKey, claims PrivyClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	s, err := tok.SignedString(priv)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return s
}

func validClaims(sub string) PrivyClaims {
	return PrivyClaims{RegisteredClaims: jwt.RegisteredClaims{
		Issuer:    "privy.io",
		Subject:   sub,
		Audience:  jwt.ClaimStrings{testAppID},
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt:  jwt.NewNumericDate(time.Now()),
	}}
}

// --- NewPrivyAuth / PEM parsing ---------------------------------------------

func TestNewPrivyAuthValidKey(t *testing.T) {
	_, keyPEM := genES256Key(t)
	if _, err := NewPrivyAuth(Config{AppID: testAppID, VerificationKey: keyPEM}, testMemStore(), testLogger()); err != nil {
		t.Fatalf("expected success, got %v", err)
	}
}

func TestNewPrivyAuthMissingConfig(t *testing.T) {
	_, keyPEM := genES256Key(t)
	cases := map[string]Config{
		"no app id": {VerificationKey: keyPEM},
		"no key":    {AppID: testAppID},
		"empty":     {},
	}
	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := NewPrivyAuth(cfg, testMemStore(), testLogger()); err == nil {
				t.Fatal("expected error for incomplete config")
			}
		})
	}
}

func TestNewPrivyAuthBadPEM(t *testing.T) {
	if _, err := NewPrivyAuth(Config{AppID: testAppID, VerificationKey: "not a pem block"}, testMemStore(), testLogger()); err == nil {
		t.Fatal("expected PEM decode error")
	}
}

func TestNewPrivyAuthNonECDSAKey(t *testing.T) {
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate rsa: %v", err)
	}
	der, err := x509.MarshalPKIXPublicKey(&rsaKey.PublicKey)
	if err != nil {
		t.Fatalf("marshal rsa: %v", err)
	}
	keyPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	if _, err := NewPrivyAuth(Config{AppID: testAppID, VerificationKey: keyPEM}, testMemStore(), testLogger()); err == nil {
		t.Fatal("expected 'not an ECDSA key' error for an RSA verification key")
	}
}

// TestNewPrivyAuthEscapedNewlines verifies the env-var workaround: a key whose
// newlines are literal backslash-n is normalized back to real newlines.
func TestNewPrivyAuthEscapedNewlines(t *testing.T) {
	_, keyPEM := genES256Key(t)
	escaped := strings.ReplaceAll(keyPEM, "\n", `\n`)
	if !strings.Contains(escaped, `\n`) {
		t.Fatal("fixture did not produce escaped newlines")
	}
	if _, err := NewPrivyAuth(Config{AppID: testAppID, VerificationKey: escaped}, testMemStore(), testLogger()); err != nil {
		t.Fatalf("expected escaped-newline key to parse, got %v", err)
	}
}

// --- VerifyToken ------------------------------------------------------------

func TestVerifyTokenValid(t *testing.T) {
	priv, keyPEM := genES256Key(t)
	a := newAuth(t, keyPEM, "", testMemStore())
	tok := signToken(t, priv, validClaims("did:privy:abc123"))
	sub, err := a.VerifyToken(tok)
	if err != nil {
		t.Fatalf("VerifyToken: %v", err)
	}
	if sub != "did:privy:abc123" {
		t.Fatalf("subject = %q, want did:privy:abc123", sub)
	}
}

func TestVerifyTokenRejectsTampered(t *testing.T) {
	priv, keyPEM := genES256Key(t)
	a := newAuth(t, keyPEM, "", testMemStore())

	otherPriv, _ := genES256Key(t)
	expired := validClaims("did:privy:abc")
	expired.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Hour))
	wrongIss := validClaims("did:privy:abc")
	wrongIss.Issuer = "evil.example"
	wrongAud := validClaims("did:privy:abc")
	wrongAud.Audience = jwt.ClaimStrings{"some-other-app"}
	noSub := validClaims("")
	noExp := validClaims("did:privy:abc")
	noExp.ExpiresAt = nil

	cases := map[string]string{
		"expired":       signToken(t, priv, expired),
		"wrong issuer":  signToken(t, priv, wrongIss),
		"wrong aud":     signToken(t, priv, wrongAud),
		"empty subject": signToken(t, priv, noSub),
		"no expiry":     signToken(t, priv, noExp),
		"wrong key":     signToken(t, otherPriv, validClaims("did:privy:abc")),
		"garbage":       "not.a.jwt",
	}
	for name, tok := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := a.VerifyToken(tok); err == nil {
				t.Fatalf("expected verification failure for %q", name)
			}
		})
	}
}

// TestVerifyTokenRejectsNonES256 ensures the keyfunc refuses an HS256 token even
// when the attacker uses the PEM bytes as the HMAC secret (the alg-confusion
// attack). The signing method gate must reject it before the key is consulted.
func TestVerifyTokenRejectsNonES256(t *testing.T) {
	_, keyPEM := genES256Key(t)
	a := newAuth(t, keyPEM, "", testMemStore())

	hs := jwt.NewWithClaims(jwt.SigningMethodHS256, validClaims("did:privy:abc"))
	tok, err := hs.SignedString([]byte(keyPEM))
	if err != nil {
		t.Fatalf("sign hs256: %v", err)
	}
	if _, err := a.VerifyToken(tok); err == nil {
		t.Fatal("expected HS256 token to be rejected (alg confusion)")
	}
}

// --- GetOrCreateUser --------------------------------------------------------

func TestGetOrCreateUserReturnsExisting(t *testing.T) {
	st := testMemStore()
	seeded := &store.User{AccountID: "acct-existing", PrivyUserID: "did:privy:existing", Email: "e@example.com"}
	if err := st.CreateUser(seeded); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	_, keyPEM := genES256Key(t)
	a := newAuth(t, keyPEM, "", st)

	got, err := a.GetOrCreateUser("did:privy:existing")
	if err != nil {
		t.Fatalf("GetOrCreateUser: %v", err)
	}
	if got.AccountID != "acct-existing" || got.Email != "e@example.com" {
		t.Fatalf("got %+v, want the seeded user", got)
	}
}

// TestGetOrCreateUserCreatesNew verifies first-auth provisioning. appSecret is
// empty so fetchUserDetails fast-fails without a network call; the user is still
// created with a fresh account ID and an empty email.
func TestGetOrCreateUserCreatesNew(t *testing.T) {
	st := testMemStore()
	_, keyPEM := genES256Key(t)
	a := newAuth(t, keyPEM, "", st)

	got, err := a.GetOrCreateUser("did:privy:brand-new")
	if err != nil {
		t.Fatalf("GetOrCreateUser: %v", err)
	}
	if got.PrivyUserID != "did:privy:brand-new" {
		t.Fatalf("privy id = %q", got.PrivyUserID)
	}
	if got.AccountID == "" {
		t.Fatal("new user should get a generated account ID")
	}

	// A second call must be idempotent — same account, no duplicate.
	again, err := a.GetOrCreateUser("did:privy:brand-new")
	if err != nil {
		t.Fatalf("GetOrCreateUser (2nd): %v", err)
	}
	if again.AccountID != got.AccountID {
		t.Fatalf("second call account ID = %q, want stable %q", again.AccountID, got.AccountID)
	}
}

// --- UserFromContext --------------------------------------------------------

func TestUserFromContext(t *testing.T) {
	u := &store.User{AccountID: "acct-1"}
	ctx := context.WithValue(context.Background(), CtxKeyUser, u)
	if got := UserFromContext(ctx); got == nil || got.AccountID != "acct-1" {
		t.Fatalf("UserFromContext = %+v, want acct-1", got)
	}
	if got := UserFromContext(context.Background()); got != nil {
		t.Fatalf("empty context should yield nil, got %+v", got)
	}
	wrong := context.WithValue(context.Background(), CtxKeyUser, "not-a-user")
	if got := UserFromContext(wrong); got != nil {
		t.Fatalf("wrong-typed value should yield nil, got %+v", got)
	}
}

// --- Config.Check -----------------------------------------------------------

func TestConfigCheck(t *testing.T) {
	if err := (Config{}).Check(); err != nil {
		t.Fatalf("auth is optional; empty config should pass, got %v", err)
	}
	if err := (Config{AppID: testAppID}).Check(); err == nil {
		t.Fatal("configured app without a verification key should fail Check")
	}
	if err := (Config{AppID: testAppID, VerificationKey: "x"}).Check(); err != nil {
		t.Fatalf("fully configured auth should pass Check, got %v", err)
	}
}
