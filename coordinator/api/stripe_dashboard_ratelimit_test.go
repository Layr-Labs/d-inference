package api

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const dashboardTestPrivyAppID = "test-privy-app"

// privySession wires a real *auth.PrivyAuth onto the server with a freshly
// generated ES256 verification key and returns a signed access token for the
// given already-seeded user. Seeding matters: GetOrCreateUser only reaches
// Privy's REST API for a DID it has never seen, and tests must not touch the
// network.
func privySession(t *testing.T, srv *Server, st *store.MemoryStore, user *store.User) string {
	t.Helper()

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatalf("marshal PKIX: %v", err)
	}
	keyPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))

	pa, err := auth.NewPrivyAuth(auth.Config{
		AppID:           dashboardTestPrivyAppID,
		VerificationKey: keyPEM,
	}, st, srv.logger)
	if err != nil {
		t.Fatalf("NewPrivyAuth: %v", err)
	}
	srv.SetPrivyAuth(pa)

	token, err := jwt.NewWithClaims(jwt.SigningMethodES256, auth.PrivyClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    "privy.io",
			Subject:   user.PrivyUserID,
			Audience:  jwt.ClaimStrings{dashboardTestPrivyAppID},
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}).SignedString(priv)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return token
}

// Every call to this route is a live Stripe POST that mints a dashboard
// credential, so a valid session must not be able to loop it and burn the
// platform's Stripe request capacity. Drive the real mux: the limiter has to
// sit inside requirePrivyAuth (it keys on the account ID that middleware puts
// in the context), and dropping it from the chain must fail CI.
func TestStripeDashboardLinkRouteIsRateLimited(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetFinancialRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))

	user := seedUser(t, st, "acct-dash-rl", "rl@example.com")
	token := privySession(t, srv, st, user)

	call := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		return w
	}

	// First call passes the limiter and reaches the handler. This user has no
	// connected account, so the handler's own gate answers 409 — what matters
	// is that the limiter let it through.
	if w := call(); w.Code != http.StatusConflict {
		t.Fatalf("first call = %d, want 409 (limiter must not reject the first request): %s", w.Code, w.Body.String())
	}

	w := call()
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("second call = %d, want 429 — the dashboard route is missing rateLimitFinancial: %s", w.Code, w.Body.String())
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("429 without Retry-After")
	}
}
