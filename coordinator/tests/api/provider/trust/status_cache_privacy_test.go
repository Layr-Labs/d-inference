package trust_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPublicAttestationRosterCachesRedactedResponse(t *testing.T) {
	s, private, _ := newAuthorizationFixture(t)
	private.Mu().Lock()
	private.PrivateOnly = true
	private.AttestationResult.PublicKey = "private-persistent-key"
	private.AttestationResult.HardwareModel = "private-hardware-marker"
	private.Mu().Unlock()
	public := s.registry.Register("public-connection", nil, &protocol.RegisterMessage{})
	public.SetAttestationResult(&attestation.VerificationResult{PublicKey: "public-verification-key"})
	t.Cleanup(func() { s.registry.Disconnect(public.ID) })
	for range 2 {
		w := httptest.NewRecorder()
		s.HandleProviderAttestation(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
		body, ok := s.readCache.Get("providers:attestation:v1")
		if !ok {
			t.Fatal("expected the redacted response to populate the shared cache")
		}
		for _, marker := range []string{private.ID, "private-persistent-key", "private-hardware-marker"} {
			if strings.Contains(string(body), `"`+marker+`"`) {
				t.Fatal("private metadata escaped", marker)
			}
		}
	}
}
