package api

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicAttestationRosterExcludesPrivateOnlyProviders(t *testing.T) {
	s, private, _ := newAuthorizationFixture(t)
	private.Mu().Lock()
	private.PrivateOnly = true
	private.AttestationResult.PublicKey = "private-persistent-key"
	private.AttestationResult.HardwareModel = "private-hardware-marker"
	private.Mu().Unlock()
	public := s.registry.Register("public-connection", nil, &protocol.RegisterMessage{})
	public.SetAttestationResult(&attestation.VerificationResult{PublicKey: "public-verification-key"})
	t.Cleanup(func() { s.registry.Disconnect(public.ID) })
	// Check both the initial response and the shared cache hit; no auth is
	// required for this route, so the private roster must never enter its cache.
	for range 2 {
		w := httptest.NewRecorder()
		s.trust.HandleProviderAttestation(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
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
		if _, ok := s.readCache.Get(providerAttestationCacheKey); !ok {
			t.Fatal("expected the redacted response to populate the shared cache")
		}
	}
	for _, account := range []string{"account", "another-account"} {
		w := httptest.NewRecorder()
		s.accounts.HandleMyProviders(w, reqWithUser(http.MethodGet, "/v1/me/providers", "", account))
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
