package provider_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPublicAttestationRosterExcludesPrivateOnlyProviders(t *testing.T) {
	f := testkit.New(t, api.ServerConfig{})
	sessions := testkit.NewSessions(t, f.Server, f.Store)
	private := f.Registry.Register("connection", nil, &protocol.RegisterMessage{})
	private.AccountID = "account"
	private.SetAttestationResult(&attestation.VerificationResult{Valid: true})
	private.Mu().Lock()
	private.PrivateOnly = true
	private.AttestationResult.PublicKey = "private-persistent-key"
	private.AttestationResult.HardwareModel = "private-hardware-marker"
	private.Mu().Unlock()
	public := f.Registry.Register("public-connection", nil, &protocol.RegisterMessage{})
	public.SetAttestationResult(&attestation.VerificationResult{PublicKey: "public-verification-key"})
	t.Cleanup(func() {
		f.Registry.Disconnect(public.ID)
		f.Registry.Disconnect(private.ID)
	})
	// Check both the initial response and the shared cache hit; no auth is
	// required for this route, so the private roster must never enter its cache.
	for range 2 {
		w := httptest.NewRecorder()
		f.Server.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
		var result struct {
			Providers []struct {
				ID  string `json:"provider_id"`
				Key string `json:"se_public_key"`
			} `json:"providers"`
		}
		if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &result) != nil {
			t.Fatal("failed roster response")
		}
		if len(result.Providers) != 1 || result.Providers[0].ID != public.ID || result.Providers[0].Key != "public-verification-key" {
			t.Fatal("public roster exposed a private connection or lost public verification")
		}
		for _, marker := range []string{private.ID, "private-persistent-key", "private-hardware-marker"} {
			if strings.Contains(w.Body.String(), `"`+marker+`"`) {
				t.Fatal("private metadata escaped", marker)
			}
		}
	}
	for _, account := range []string{"account", "another-account"} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodGet, "/v1/me/providers", nil)
		r.Header.Set("Authorization", "Bearer "+sessions.Token(account))
		f.Server.Handler().ServeHTTP(w, r)
		var result struct {
			Providers []struct {
				ID string `json:"id"`
			} `json:"providers"`
		}
		if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &result) != nil {
			t.Fatal("failed owner fleet response")
		}
		if account == "account" && (len(result.Providers) != 1 || result.Providers[0].ID != private.ID) {
			t.Fatal("public redaction removed the private machine from its owner's fleet")
		}
		if account != "account" && len(result.Providers) != 0 {
			t.Fatal("private machine became visible to another account")
		}
	}
}
