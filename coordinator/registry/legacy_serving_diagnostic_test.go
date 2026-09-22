package registry

import (
	"testing"
	"time"
)

func TestLegacyServingDenialReasonIdentifiesClosedGateWithoutGranting(t *testing.T) {
	r := New(testLogger())
	r.SetCodeAttestationPolicy(true, time.Now().Add(-time.Hour))
	p := makeSchedulerProvider(t, r, "legacy-diagnostic", "qwen-3-32b", 80)
	t.Cleanup(func() { r.Disconnect(p.ID) })
	p.mu.Lock()
	p.CodeAttested = true
	p.mu.Unlock()
	if !r.ProviderLegacyServingAuthorized(p) || r.ProviderLegacyServingDenialReason(p) != "" {
		t.Fatal("precondition: legacy provider should be authorized")
	}

	checks := []struct {
		name   string
		change func()
		undo   func()
		want   string
	}{
		{"code identity", func() { p.CodeAttested = false }, func() { p.CodeAttested = true }, "legacy_code_identity_unverified"},
		{"SIP challenge", func() { p.ChallengeVerifiedSIP = false }, func() { p.ChallengeVerifiedSIP = true }, "legacy_sip_unverified"},
		{"challenge age", func() { p.LastChallengeVerified = time.Now().Add(-time.Hour) }, func() { p.LastChallengeVerified = time.Now() }, "legacy_challenge_stale"},
		{"runtime manifest", func() { p.RuntimeManifestChecked = false }, func() { p.RuntimeManifestChecked = true }, "legacy_runtime_manifest_unverified"},
	}
	for _, check := range checks {
		t.Run(check.name, func(t *testing.T) {
			p.mu.Lock()
			check.change()
			p.mu.Unlock()
			defer func() { p.mu.Lock(); check.undo(); p.mu.Unlock() }()
			if r.ProviderLegacyServingAuthorized(p) {
				t.Fatal("failed gate granted legacy serving")
			}
			if got := r.ProviderLegacyServingDenialReason(p); got != check.want {
				t.Fatalf("reason = %q, want %q", got, check.want)
			}
		})
	}
	if !r.ProviderLegacyServingAuthorized(p) || r.ProviderLegacyServingDenialReason(p) != "" {
		t.Fatal("diagnostic changed serving authorization")
	}
	if got := r.ProviderLegacyServingDenialReason(nil); got != "" {
		t.Fatalf("nil provider exposed reason %q", got)
	}
}

func TestLegacyServingDenialReasonExplainsReleaseEvidenceOnlyWhenEnforced(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "release-diagnostic", "qwen-3-32b", 80)
	t.Cleanup(func() { r.Disconnect(p.ID) })
	r.SetReleasePolicyGeneration(7, true, nil)
	if !r.ProviderLegacyServingAuthorized(p) || r.ProviderLegacyServingDenialReason(p) != "" {
		t.Fatal("shadow release evidence became a serving gate")
	}
	r.SetReleasePolicyEnforcement(true)
	if r.ProviderLegacyServingAuthorized(p) {
		t.Fatal("missing enforced release evidence granted serving")
	}
	if got := r.ProviderLegacyServingDenialReason(p); got != "legacy_release_evidence_missing" {
		t.Fatalf("reason = %q", got)
	}
}
