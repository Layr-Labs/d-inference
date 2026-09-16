package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A registered route must observe credential replacement. Capturing configuration
// while mounting middleware would silently keep an old admin key or JWT verifier.
func TestAuthenticationUsesCurrentCredentials(t *testing.T) {
	srv, st := newKeyTestServer(t)
	t.Cleanup(srv.Close)
	handler := srv.Handler()
	user := &store.User{AccountID: "auth-current-user", PrivyUserID: "did:privy:auth-current"}
	if err := st.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	for account, amount := range map[string]int64{"admin": 17, user.AccountID: 29} {
		if err := st.Credit(account, amount, store.LedgerAdminCredit, "auth-test"); err != nil {
			t.Fatal(err)
		}
	}
	balance := func(token string, want int64) {
		t.Helper()
		w := authContractRequest(t, handler, http.MethodGet, "/v1/payments/balance", token, "", http.StatusOK)
		var got types.BalanceResponse
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if got.BalanceMicroUSD != want {
			t.Fatalf("balance = %d, want %d for the resolved identity", got.BalanceMicroUSD, want)
		}
	}

	srv.SetAdminKey("auth-admin-before")
	balance("auth-admin-before", 17)
	srv.SetAdminKey("auth-admin-after")
	authContractRequest(t, handler, http.MethodGet, "/v1/payments/balance", "auth-admin-before", "", http.StatusUnauthorized)
	balance("auth-admin-after", 17)
	srv.SetAdminKey("")
	authContractRequest(t, handler, http.MethodGet, "/v1/payments/balance", "auth-admin-after", "", http.StatusUnauthorized)

	firstSession := privySession(t, srv, st, user)
	balance(firstSession, 29)
	authContractRequest(t, handler, http.MethodGet, "/v1/keys", firstSession, "", http.StatusOK)
	secondSession := privySession(t, srv, st, user)
	// JWT-shaped credentials are checked by Privy before considering the admin key.
	srv.SetAdminKey(firstSession)
	authContractRequest(t, handler, http.MethodGet, "/v1/payments/balance", firstSession, "", http.StatusUnauthorized)
	authContractRequest(t, handler, http.MethodGet, "/v1/keys", firstSession, "", http.StatusUnauthorized)
	balance(secondSession, 29)
	authContractRequest(t, handler, http.MethodGet, "/v1/keys", secondSession, "", http.StatusOK)
	srv.SetAdminKey("")
	srv.SetPrivyAuth(nil)
	authContractRequest(t, handler, http.MethodGet, "/v1/payments/balance", secondSession, "", http.StatusUnauthorized)
	authContractRequest(t, handler, http.MethodGet, "/v1/keys", secondSession, "", http.StatusForbidden)

	key, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{Name: "auth-admin-precedence"})
	if err != nil {
		t.Fatal(err)
	}
	// The admin credential also takes precedence over a valid persisted API key.
	srv.SetAdminKey(key)
	balance(key, 17)
	srv.SetAdminKey("")
	balance(key, 29)
}

type authContractStore struct {
	store.Store
	keyReads atomic.Int64
}

func (s *authContractStore) AuthenticateKey(token string) (*store.APIKey, error) {
	s.keyReads.Add(1)
	return s.Store.AuthenticateKey(token)
}

// Mutations use the real registered routes and the same cache as inference auth.
// Provider tokens must remain uncached because they have a separate revoke path.
func TestAuthenticationCacheFollowsCredentialLifecycle(t *testing.T) {
	srv, st := newKeyTestServer(t)
	t.Cleanup(srv.Close)
	counting := &authContractStore{Store: st}
	// Install after NewServer: authentication must read the live persistence binding.
	srv.store = counting
	user := &store.User{AccountID: "auth-lifecycle-user", PrivyUserID: "did:privy:auth-lifecycle"}
	if err := st.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	session := privySession(t, srv, st, user)
	handler := srv.Handler()
	key, record, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{Name: "auth-lifecycle"})
	if err != nil {
		t.Fatal(err)
	}
	checkKey := func(token string, status int) {
		t.Helper()
		authContractRequest(t, handler, http.MethodGet, "/v1/payments/balance", token, "", status)
	}
	checkKey(key, http.StatusOK)
	checkKey(key, http.StatusOK)
	if got := counting.keyReads.Load(); got != 1 {
		t.Fatalf("repeated key lookup made %d persistence reads, want one cached read", got)
	}

	path := "/v1/keys/" + record.ID
	authContractRequest(t, handler, http.MethodPatch, path, session, `{"disabled":true}`, http.StatusOK)
	checkKey(key, http.StatusUnauthorized)
	authContractRequest(t, handler, http.MethodPatch, path, session, `{"disabled":false}`, http.StatusOK)
	checkKey(key, http.StatusOK)
	w := authContractRequest(t, handler, http.MethodPost, path+"/rotate", session, "", http.StatusOK)
	var rotated types.CreateAPIKeyResponse
	if err := json.Unmarshal(w.Body.Bytes(), &rotated); err != nil {
		t.Fatal(err)
	}
	checkKey(key, http.StatusUnauthorized)
	checkKey(rotated.Key, http.StatusOK)
	authContractRequest(t, handler, http.MethodDelete, "/v1/keys/"+rotated.Data.ID, session, "", http.StatusOK)
	checkKey(rotated.Key, http.StatusUnauthorized)

	// The legacy raw-token revocation route invalidates the same positive cache.
	rawRevokedKey, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{Name: "auth-raw-revoke"})
	if err != nil {
		t.Fatal(err)
	}
	checkKey(rawRevokedKey, http.StatusOK)
	body, err := json.Marshal(map[string]string{"key": rawRevokedKey})
	if err != nil {
		t.Fatal(err)
	}
	authContractRequest(t, handler, http.MethodDelete, "/v1/auth/keys", session, string(body), http.StatusOK)
	checkKey(rawRevokedKey, http.StatusUnauthorized)

	const providerToken = "auth-provider-device-token"
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: store.HashKey(providerToken), AccountID: user.AccountID, Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	checkKey(providerToken, http.StatusOK)
	if err := st.RevokeProviderToken(providerToken); err != nil {
		t.Fatal(err)
	}
	checkKey(providerToken, http.StatusUnauthorized)
}

func authContractRequest(t *testing.T, handler http.Handler, method, path, token, body string, wantStatus int) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != wantStatus {
		t.Fatalf("%s %s status = %d, want %d: %s", method, path, w.Code, wantStatus, w.Body.String())
	}
	return w
}
