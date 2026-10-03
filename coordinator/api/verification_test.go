package api

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/reporting"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestVerificationHeadersMetadataAndRevocation(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	v := s.registry.ProviderVerification(p)
	info := inresp.CollectCommittedProviderInfo(p)
	info.Verification = &v
	w := httptest.NewRecorder()
	inresp.WriteCommittedProviderHeaders(w, info)
	if w.Header().Get("X-Provider-Trust-Level") != "self_signed" || w.Header().Get("X-Provider-Authorization-Method") != "app_attest" {
		t.Fatal(w.Header())
	}
	pr := &registry.PendingRequest{RequestID: "job", MetadataDetails: true}
	inresp.SnapshotChatCompletionMetadata(pr, info)
	var meta types.ChatCompletionMetadata
	if err := json.Unmarshal(pr.ResponseMetadata, &meta); err != nil {
		t.Fatal(err)
	}
	header, err := json.Marshal(meta.Verification)
	if err != nil || string(header) != w.Header().Get("X-Provider-Verification") {
		t.Fatalf("header/body mismatch: %s, %v", header, err)
	}
	s.registry.RevokeAppAttestCredential("credential")
	if meta.Verification.Method() != "app_attest" || s.registry.ProviderVerification(p).Method() != "none" {
		t.Fatal("historical and live verdicts were conflated")
	}
	for _, forbidden := range []string{"credential", "account", "machine_id", "serial", "receipt", "certificate"} {
		if strings.Contains(string(header), forbidden) {
			t.Fatalf("public header leaked %s", forbidden)
		}
	}
}

func TestVerificationCountsUnionAndDenominators(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	s.readCache = readcache.New()
	s.reporting = reporting.New(reporting.Dependencies{Store: s.store, Registry: s.registry, Cache: s.readCache, Logger: s.logger})
	p.AttestationResult.OSVersion = "27.0.0"
	counts := s.publicVerificationCounts(t)
	if counts.Authorized != 1 || counts.KnownMachines != 1 || counts.ReportedMacOS27 != 1 || counts.ReportedOS != 1 {
		t.Fatalf("public denominators: %+v", counts)
	}
	s.registry.ClearAppAttestServingAuthorization(p)
	counts = s.publicVerificationCounts(t)
	if counts.Authorized != 0 || counts.ReportedMacOS27 != 1 {
		t.Fatal("reported OS was confused with authorization")
	}
	p.PrivateOnly = true
	if counts = s.publicVerificationCounts(t); counts.Connections != 0 || counts.KnownMachines != 0 {
		t.Fatal("private provider entered public counts")
	}
}

// Exercise the reporting handler rather than reaching into its private accumulator.
func (s *Server) publicVerificationCounts(t *testing.T) verificationSnapshotCounts {
	t.Helper()
	var body struct {
		Counts verificationSnapshotCounts `json:"verification_counts"`
	}
	if err := json.Unmarshal(freshStatsBody(t, s), &body); err != nil {
		t.Fatal(err)
	}
	return body.Counts
}
