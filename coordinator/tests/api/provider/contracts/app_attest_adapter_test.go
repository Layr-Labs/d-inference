package provider_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestAdminRevocationOwnershipAndIdempotency(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	s.SetAdminKey("admin-secret")
	keys, _ := store.As[store.AppAttestShadowStore](s.store)
	_, err := keys.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: "credential", AccountID: "account"})
	if err != nil {
		t.Fatal(err)
	}
	call := func(account, token string) int {
		r := httptest.NewRequest(http.MethodPost, "/v1/admin/app-attest/revoke", strings.NewReader(`{"key_id":"credential","account_id":"`+account+`","reason":"operator_revoked"}`))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		return w.Code
	}
	if got := call("account", "wrong"); got == http.StatusOK {
		t.Fatal("unauthenticated revoke")
	}
	if got := call("other", "admin-secret"); got != http.StatusNotFound {
		t.Fatalf("account mismatch %d", got)
	}
	if _, valid := s.registry.ProviderServingAuthorization(p); !valid {
		t.Fatal("wrong account revoked lease")
	}
	for i := 0; i < 2; i++ {
		if got := call("account", "admin-secret"); got != http.StatusOK {
			t.Fatalf("revocation %d", got)
		}
	}
	if _, valid := s.registry.ProviderServingAuthorization(p); valid {
		t.Fatal("successful revocation did not fence")
	}
}

func TestAppAttestPublicAuthorizationDoesNotExposePrivateIdentity(t *testing.T) {
	s, _, _ := newAuthorizationFixture(t)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"app_attest_authorized":true`) {
		t.Fatalf("public verdict %d %s", w.Code, w.Body.String())
	}
	for _, field := range []string{`"account_id"`, `"machine_id"`, `"credential_id"`, `"key_id"`, `"serial_number"`, `"receipt"`} {
		if strings.Contains(w.Body.String(), field) {
			t.Fatalf("private field %s", field)
		}
	}
}
