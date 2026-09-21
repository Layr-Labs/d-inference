package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPublicVerificationRowsRemainConsistentDuringRegistrationAndGrantChanges(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	lease := p.GetAppAttestServingAuthorization()
	var workers sync.WaitGroup
	workers.Add(1)
	go func() {
		defer workers.Done()
		for i := range 200 {
			s.registry.ClearAppAttestServingAuthorization(p)
			id := fmt.Sprintf("joining-%d", i)
			s.registry.Register(id, nil, &protocol.RegisterMessage{PublicKey: id})
			s.registry.GrantAppAttestServingAuthorization(p, lease)
			s.registry.Disconnect(id)
		}
	}()
	defer workers.Wait()
	states := map[string]bool{"verified": true, "pending": true, "expired": true, "revoked": true, "unsupported": true, "offline": true}
	for range 200 {
		w := httptest.NewRecorder()
		s.handleProviderAttestation(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
		var body struct {
			Providers []struct {
				Verification registry.Verification `json:"verification"`
				Authorized   bool                  `json:"app_attest_authorized"`
				ExpiresAt    int64                 `json:"authorization_expires_at"`
			} `json:"providers"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		for _, row := range body.Providers {
			v := row.Verification
			if v.ObservedAt <= 0 || !states[v.AppAttest.State] || !states[v.Legacy.State] {
				t.Fatalf("invalid verdict: %+v", row)
			}
			if row.Authorized != (v.AppAttest.State == "verified") {
				t.Fatalf("contradictory verdicts: %+v", row)
			}
			if row.Authorized && row.ExpiresAt != v.AppAttest.ExpiresAt {
				t.Fatalf("mismatched deadlines: %+v", row)
			}
			if !row.Authorized && row.ExpiresAt != 0 {
				t.Fatalf("unauthorized lease deadline: %+v", row)
			}
		}
	}
}
