package api

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestVerificationHeadersMetadataAndRevocation(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	v := s.registry.ProviderVerification(p)
	info := collectCommittedProviderInfo(p)
	info.Verification = &v
	w := httptest.NewRecorder()
	writeCommittedProviderHeaders(w, info)
	if w.Header().Get("X-Provider-Trust-Level") != "self_signed" || w.Header().Get("X-Provider-Authorization-Method") != "app_attest" {
		t.Fatal(w.Header())
	}
	meta := buildChatCompletionMetadata(info, "job", nil)
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
	verified := registry.VerificationPath{State: "verified", VerifiedAt: 1, ExpiresAt: 9999999999}
	pending := registry.VerificationPath{State: "pending"}
	var counts verificationCounts
	for _, v := range []registry.Verification{
		{AppAttest: verified, Legacy: pending}, {AppAttest: pending, Legacy: verified},
		{AppAttest: verified, Legacy: verified}, {AppAttest: pending, Legacy: pending},
	} {
		counts.add(v)
	}
	if counts.Connections != 4 || counts.Authorized != 3 || counts.AppAttest != 2 || counts.Legacy != 2 || counts.Overlap != 1 {
		t.Fatalf("double counted union: %+v", counts)
	}
	s, p, _ := newAuthorizationFixture(t)
	p.AttestationResult.OSVersion = "27.0.0"
	counts = s.publicVerificationCounts(s.registry.ProviderVerifications())
	var duplicate verificationCounts
	machines := map[[2]string]struct{}{}
	for range 2 {
		duplicate.addProvider(p, s.registry.ProviderVerification(p), machines)
	}
	if duplicate.Connections != 2 || duplicate.KnownMachines != 1 {
		t.Fatalf("machine denominator: %+v", duplicate)
	}
	if counts.Authorized != 1 || counts.KnownMachines != 1 || counts.ReportedMacOS27 != 1 || counts.ReportedOS != 1 {
		t.Fatalf("public denominators: %+v", counts)
	}
	s.registry.ClearAppAttestServingAuthorization(p)
	counts = s.publicVerificationCounts(s.registry.ProviderVerifications())
	if counts.Authorized != 0 || counts.ReportedMacOS27 != 1 {
		t.Fatal("reported OS was confused with authorization")
	}
	p.PrivateOnly = true
	if counts = s.publicVerificationCounts(s.registry.ProviderVerifications()); counts.Connections != 0 || counts.KnownMachines != 0 {
		t.Fatal("private provider entered public counts")
	}
}

func TestOwnerVerificationRemainsOfflineAndAccountScoped(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	mp := buildMyProvider(nil, p)
	s.attachMyProviderAuthorization(&mp, p, "other-account")
	if mp.Verification.Method() != "none" || mp.Verification.AppAttest.State != "offline" {
		t.Fatal("wrong owner obtained current evidence")
	}
	s.attachMyProviderAuthorization(&mp, p, "account")
	if mp.Verification.AppAttest.ExpiresAt <= time.Now().Unix() {
		t.Fatal("owner lost verified expiry")
	}
}

// Exercise exactly the row accumulator used by computeStats.
func (s *Server) publicVerificationCounts(verifications map[string]registry.Verification) verificationCounts {
	var c verificationCounts
	machines := map[[2]string]struct{}{}
	s.registry.ForEachProvider(func(p *registry.Provider) {
		if !p.PrivateOnly {
			c.addProvider(p, verifications[p.ID], machines)
		}
	})
	return c
}
