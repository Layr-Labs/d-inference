package testkit

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/golang-jwt/jwt/v5"
)

// PrivyUsers answers Privy's get-user and delete-user API in process.
// NewPrivyUsers connects a real PrivyAuth to it, so logins look up Privy users
// and the erasure outbox deletes them here instead of at auth.privy.io.
type PrivyUsers struct {
	t       testing.TB
	key     *ecdsa.PrivateKey
	mu      sync.Mutex
	status  int
	failure error
	deleted []string
	// gone holds the user IDs that a delete removed (204) or that Privy did
	// not have (404). A get of one of them answers 404.
	gone map[string]bool
	// lookups counts the get-user requests.
	lookups int
}

const (
	privyUsersAppID     = "test-privy-app"
	privyUsersAppSecret = "test-privy-secret"
)

// NewPrivyUsers installs the in-process API on srv. It answers 204 until
// SetStatus or SetTransportError changes the answer.
func NewPrivyUsers(t testing.TB, srv *api.Server, st store.Store) *PrivyUsers {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	p := &PrivyUsers{t: t, key: key, status: http.StatusNoContent, gone: map[string]bool{}}
	pa, err := auth.NewPrivyAuth(auth.Config{
		AppID: privyUsersAppID, AppSecret: privyUsersAppSecret,
		VerificationKey: string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})),
		HTTPClient:      &http.Client{Transport: p},
	}, st, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	srv.SetPrivyAuth(pa)
	return p
}

// SetStatus sets the HTTP status of later answers.
func (p *PrivyUsers) SetStatus(status int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.status, p.failure = status, nil
}

// SetTransportError makes later requests fail before an answer.
func (p *PrivyUsers) SetTransportError(err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.failure = err
}

// Deleted returns the user IDs of the delete requests received.
func (p *PrivyUsers) Deleted() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.deleted...)
}

// Lookups returns how many get-user requests the API received.
func (p *PrivyUsers) Lookups() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.lookups
}

// Token returns a Privy access token for the user ID, valid for one hour.
// It creates no user.
func (p *PrivyUsers) Token(privyUserID string) string {
	p.t.Helper()
	token, err := jwt.NewWithClaims(jwt.SigningMethodES256, auth.PrivyClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer: "privy.io", Subject: privyUserID,
			Audience:  jwt.ClaimStrings{privyUsersAppID},
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}).SignedString(p.key)
	if err != nil {
		p.t.Fatal(err)
	}
	return token
}

// RoundTrip checks the request against Privy's documented user calls:
// GET or DELETE https://auth.privy.io/api/v1/users/<did>, Basic auth with the
// app ID and secret, and the privy-app-id header. A get answers 404 for a
// deleted user and an empty user otherwise.
func (p *PrivyUsers) RoundTrip(r *http.Request) (*http.Response, error) {
	id, secret, ok := r.BasicAuth()
	if (r.Method != http.MethodDelete && r.Method != http.MethodGet) || r.URL.Scheme != "https" || r.URL.Host != "auth.privy.io" ||
		!strings.HasPrefix(r.URL.Path, "/api/v1/users/") || !ok || id != privyUsersAppID ||
		secret != privyUsersAppSecret || r.Header.Get("Privy-App-Id") != privyUsersAppID {
		p.t.Errorf("unexpected Privy request: %s %s", r.Method, r.URL)
		return nil, errors.New("unexpected Privy request")
	}
	user := strings.TrimPrefix(r.URL.Path, "/api/v1/users/")
	p.mu.Lock()
	defer p.mu.Unlock()
	if r.Method == http.MethodGet {
		p.lookups++
		if p.gone[user] {
			return &http.Response{StatusCode: http.StatusNotFound, Body: http.NoBody, Header: http.Header{}, Request: r}, nil
		}
		body := `{"id":` + strconv.Quote(user) + `,"linked_accounts":[]}`
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}, Request: r}, nil
	}
	p.deleted = append(p.deleted, user)
	if p.failure != nil {
		return nil, p.failure
	}
	if p.status == http.StatusNoContent || p.status == http.StatusNotFound {
		p.gone[user] = true
	}
	return &http.Response{StatusCode: p.status, Body: http.NoBody, Header: http.Header{}, Request: r}, nil
}
