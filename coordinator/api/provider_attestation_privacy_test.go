package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPublicAttestationRosterExcludesPrivateOnlyProviders(t *testing.T) {
	s, private, _ := newAuthorizationFixture(t)
	s.readCache = newTTLCache()
	private.PrivateOnly = true
	private.AttestationResult.PublicKey = "private-persistent-key"
	private.AttestationResult.HardwareModel = "private-hardware-marker"
	public := s.registry.Register("public-connection", nil, &protocol.RegisterMessage{})
	public.AttestationResult = &attestation.VerificationResult{PublicKey: "public-verification-key"}
	t.Cleanup(func() { s.registry.Disconnect(public.ID) })
	// Check both the initial response and the shared cache hit; no auth is
	// required for this route, so the private roster must never enter its cache.
	for range 2 {
		w := httptest.NewRecorder()
		s.handleProviderAttestation(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
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
		if _, ok := s.readCacheGet(providerAttestationCacheKey); !ok {
			t.Fatal("expected the redacted response to populate the shared cache")
		}
	}
	ownerFleet, err := s.mergeFleet(context.Background(), "account")
	if err != nil || len(ownerFleet) != 1 || ownerFleet[0].ID != private.ID {
		t.Fatal("public redaction removed the private machine from its owner's fleet", err)
	}
	otherFleet, err := s.mergeFleet(context.Background(), "another-account")
	if err != nil || len(otherFleet) != 0 {
		t.Fatal("private machine became visible to another account", err)
	}
}
