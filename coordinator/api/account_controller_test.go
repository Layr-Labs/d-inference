package api

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Controller extraction must preserve the runtime bindings that existing tests
// and server wiring can replace after NewServer registers its routes.
func TestAccountControllerUsesCurrentBindings(t *testing.T) {
	srv, original := newKeyTestServer(t)
	t.Cleanup(srv.Close)
	user := &store.User{AccountID: "account-binding-user", PrivyUserID: "did:privy:account-binding", Email: "account-admin@example.com"}
	if err := original.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	session := privySession(t, srv, original, user)
	handler := srv.Handler()

	t.Run("current store", func(t *testing.T) {
		replacement := store.NewMemory(store.Config{})
		srv.store = replacement
		w := authContractRequest(t, handler, http.MethodPost, "/v1/keys", session, `{"name":"current-store"}`, http.StatusOK)
		var created types.CreateAPIKeyResponse
		if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
			t.Fatal(err)
		}
		if _, err := replacement.AuthenticateKey(created.Key); err != nil {
			t.Fatalf("created key was not written to the current store: %v", err)
		}
		oldKeys, err := original.ListAPIKeys(user.AccountID)
		if err != nil || len(oldKeys) != 0 {
			t.Fatalf("route wrote to old store: keys=%d, err=%v", len(oldKeys), err)
		}
	})

	t.Run("current console URL", func(t *testing.T) {
		for _, console := range []string{"https://console-one.example/", "https://console-two.example"} {
			srv.consoleURL = console
			w := authContractRequest(t, handler, http.MethodPost, "/v1/device/code", "", "", http.StatusOK)
			var got struct {
				VerificationURI string `json:"verification_uri"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			want := console
			if want[len(want)-1] == '/' {
				want = want[:len(want)-1]
			}
			if got.VerificationURI != want+"/link" {
				t.Fatalf("verification URI = %q, want current console %q", got.VerificationURI, want+"/link")
			}
		}
	})

	t.Run("current admin policy", func(t *testing.T) {
		// The outer auth middleware already accepts this session. It is the
		// controller's in-handler authorization that must see these changes.
		srv.SetAdminEmails([]string{user.Email})
		authContractRequest(t, handler, http.MethodGet, "/v1/admin/invite-codes", session, "", http.StatusOK)
		srv.SetAdminEmails(nil)
		authContractRequest(t, handler, http.MethodGet, "/v1/admin/invite-codes", session, "", http.StatusForbidden)
	})
}
