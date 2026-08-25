package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAdminRoutesRejectMachineCredentialsOwnedByAdmin(t *testing.T) {
	srv, st := testServer(t)
	const (
		accountID = "acct-admin-machine-credential"
		email     = "admin@example.com"
	)
	if err := st.CreateUser(&store.User{
		AccountID: accountID, PrivyUserID: "did:privy:admin-machine",
		Email: email, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	srv.SetAdminEmails([]string{email})

	apiKey, _, err := st.CreateAPIKey(accountID, store.APIKeyCreate{Name: "admin-owned"})
	if err != nil {
		t.Fatal(err)
	}
	providerToken := "provider-admin-owned-token"
	tokenHash := sha256.Sum256([]byte(providerToken))
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: hex.EncodeToString(tokenHash[:]),
		AccountID: accountID,
		Active:    true,
		CreatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}

	for name, token := range map[string]string{
		"api_key":        apiKey,
		"provider_token": providerToken,
	} {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(
				http.MethodGet, "/v1/admin/hardware-admission/machines", nil)
			req.Header.Set("Authorization", "Bearer "+token)
			response := httptest.NewRecorder()
			srv.Handler().ServeHTTP(response, req)
			if response.Code != http.StatusForbidden {
				t.Fatalf("status = %d, want 403: %s",
					response.Code, response.Body.String())
			}
		})
	}
}
