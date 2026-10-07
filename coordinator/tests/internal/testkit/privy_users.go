package testkit

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// PrivyUsers answers Privy's delete-user API in process. NewPrivyUsers
// connects a real PrivyAuth to it, so the erasure outbox deletes Privy users
// here instead of at auth.privy.io.
type PrivyUsers struct {
	t       testing.TB
	mu      sync.Mutex
	status  int
	failure error
	deleted []string
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
	p := &PrivyUsers{t: t, status: http.StatusNoContent}
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

// RoundTrip checks the request against Privy's documented delete-user call:
// DELETE https://auth.privy.io/api/v1/users/<did>, Basic auth with the app ID
// and secret, and the privy-app-id header.
func (p *PrivyUsers) RoundTrip(r *http.Request) (*http.Response, error) {
	id, secret, ok := r.BasicAuth()
	if r.Method != http.MethodDelete || r.URL.Scheme != "https" || r.URL.Host != "auth.privy.io" ||
		!strings.HasPrefix(r.URL.Path, "/api/v1/users/") || !ok || id != privyUsersAppID ||
		secret != privyUsersAppSecret || r.Header.Get("Privy-App-Id") != privyUsersAppID {
		p.t.Errorf("unexpected Privy request: %s %s", r.Method, r.URL)
		return nil, errors.New("unexpected Privy request")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.deleted = append(p.deleted, strings.TrimPrefix(r.URL.Path, "/api/v1/users/"))
	if p.failure != nil {
		return nil, p.failure
	}
	return &http.Response{StatusCode: p.status, Body: http.NoBody, Header: http.Header{}, Request: r}, nil
}
