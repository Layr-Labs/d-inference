package testkit

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/golang-jwt/jwt/v5"
)

// Sessions signs local Privy-compatible tokens. Users are seeded before tokens
// are issued, so authentication never needs Privy's remote user API or JWKS.
type Sessions struct {
	t     testing.TB
	key   *ecdsa.PrivateKey
	store store.Store
}

func NewSessions(t testing.TB, srv *api.Server, st store.Store) *Sessions {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pa, err := auth.NewPrivyAuth(auth.Config{
		AppID:           "test-privy-app",
		VerificationKey: string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})),
	}, st, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	srv.SetPrivyAuth(pa)
	return &Sessions{t: t, key: key, store: st}
}

func (s *Sessions) Token(accountID string) string {
	s.t.Helper()
	user, _ := s.store.GetUserByAccountID(accountID)
	if user == nil {
		user = &store.User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID}
		if err := s.store.CreateUser(user); err != nil {
			s.t.Fatal(err)
		}
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodES256, auth.PrivyClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer: "privy.io", Subject: user.PrivyUserID,
			Audience:  jwt.ClaimStrings{"test-privy-app"},
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}).SignedString(s.key)
	if err != nil {
		s.t.Fatal(err)
	}
	return token
}
