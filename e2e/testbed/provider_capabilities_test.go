package testbed

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func capabilityProvider() *registry.Provider {
	capabilities := []string{registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityMLXNAX}
	return &registry.Provider{
		ID: "candidate", Hardware: protocol.Hardware{ChipFamily: "M5"},
		ReportedRuntimeCapabilities: capabilities,
		TemplateHashes:              map[string]string{"mlx_metallib": "bound-library"},
		AttestationResult: &attestation.VerificationResult{
			Valid: true, ChipFamily: "M5", MetallibHash: "bound-library",
			RuntimeCapabilities: append([]string(nil), capabilities...),
		},
	}
}

func TestProviderCapabilityEvidence(t *testing.T) {
	tests := []struct {
		name   string
		change func(*registry.Provider)
		want   string
	}{
		{"valid", func(*registry.Provider) {}, ""},
		{"missing requirement first", func(p *registry.Provider) {
			p.ReportedRuntimeCapabilities = nil
			p.TemplateHashes = nil
			p.AttestationResult = nil
		}, "missing \"apple_m5\""},
		{"reported hardware", func(p *registry.Provider) { p.Hardware.ChipFamily = "M4" }, "want M5"},
		{"library before signature", func(p *registry.Provider) {
			p.TemplateHashes = nil
			p.AttestationResult = nil
		}, "did not bind mlx_metallib"},
		{"absent signature", func(p *registry.Provider) { p.AttestationResult = nil }, "no valid registration-verified"},
		{"invalid signature", func(p *registry.Provider) { p.AttestationResult.Valid = false }, "no valid registration-verified"},
		{"signed hardware", func(p *registry.Provider) { p.AttestationResult.ChipFamily = "M4" }, "signed chip_family"},
		{"signed subset", func(p *registry.Provider) {
			p.AttestationResult.RuntimeCapabilities = p.AttestationResult.RuntimeCapabilities[:1]
		}, "signed capabilities"},
		{"signed superset", func(p *registry.Provider) {
			p.AttestationResult.RuntimeCapabilities = append(p.AttestationResult.RuntimeCapabilities, "extra")
		}, "signed capabilities"},
		{"different equal-sized set", func(p *registry.Provider) {
			p.AttestationResult.RuntimeCapabilities[1] = "other"
		}, "signed capabilities"},
		{"set order and duplicates", func(p *registry.Provider) {
			p.AttestationResult.RuntimeCapabilities = []string{registry.ProviderCapabilityMLXNAX, registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityAppleM5}
		}, ""},
		{"signed library", func(p *registry.Provider) { p.AttestationResult.MetallibHash = "different" }, "signed mlx_metallib"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := capabilityProvider()
			tt.change(p)
			before := p.GetAttestationResult()
			got := providerCapabilityMismatch(p, []string{registry.ProviderCapabilityAppleM5})
			if (tt.want == "" && got != "") || (tt.want != "" && !strings.Contains(got, tt.want)) {
				t.Fatalf("evidence refusal = %q, want %q", got, tt.want)
			}
			if !reflect.DeepEqual(before, p.GetAttestationResult()) || p.Attested || p.RuntimeVerified {
				t.Fatal("checking evidence changed signed claims or granted trust")
			}
		})
	}
}

func TestSuiteAdmissionSnapshotsOriginalPrivacy(t *testing.T) {
	reg := registry.New(kvExpectationLogger())
	for _, id := range []string{"reported", "silent"} {
		registerExpectationProvider(reg, id)
	}
	reg.GetProvider("reported").PrivacyCapabilities = &protocol.PrivacyCapabilities{SIPEnabled: true}
	reg.GetProvider("reported").AccountID = "original-owner"
	s := &Suite{Logger: kvExpectationLogger(), Coordinator: &Coordinator{Registry: reg},
		Users: []UserAccount{{AccountID: "fallback-owner"}}}
	if err := s.admitRegisteredProviders(); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"reported", "silent"} {
		p := reg.GetProvider(id)
		if p.TrustLevel != registry.TrustSelfSigned || !p.PrivacyCapabilities.TextBackendInprocess {
			t.Fatalf("%s did not receive ordinary test trust", id)
		}
		original, ok := s.ReportedPrivacyCapabilities(id)
		if !ok || (id == "silent" && original != nil) || (id == "reported" && (original == nil || original.TextBackendInprocess || !original.SIPEnabled)) {
			t.Fatalf("%s: synthetic trust overwrote original evidence: %+v", id, original)
		}
	}
	if reg.GetProvider("reported").AccountID != "original-owner" || reg.GetProvider("silent").AccountID != "fallback-owner" {
		t.Fatal("account fallback changed existing ownership")
	}
}

func TestSuiteAdmissionRejectsUnsignedCapabilityBeforePromotion(t *testing.T) {
	reg := registry.New(kvExpectationLogger())
	p := reg.Register("unsigned", nil, &protocol.RegisterMessage{
		Hardware:            protocol.Hardware{ChipFamily: "M5"},
		RuntimeCapabilities: []string{registry.ProviderCapabilityAppleM5},
	})
	s := &Suite{Logger: kvExpectationLogger(), Coordinator: &Coordinator{Registry: reg},
		Config: SuiteConfig{ExpectedProviderCapabilities: []string{registry.ProviderCapabilityAppleM5}}}
	if err := s.admitRegisteredProviders(); !errors.Is(err, ErrProviderIneligible) {
		t.Fatalf("unsigned claims admitted: %v", err)
	}
	if p.Attested || p.TrustLevel == registry.TrustHardware || len(p.RuntimeCapabilities) != 0 {
		t.Fatal("rejected provider gained protected capabilities")
	}
	if _, ok := s.ReportedPrivacyCapabilities(p.ID); ok {
		t.Fatal("failed admission published a successful registration snapshot")
	}
}
