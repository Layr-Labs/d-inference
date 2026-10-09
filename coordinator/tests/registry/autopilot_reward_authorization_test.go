package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func rewardReceiptAuthorization(t *testing.T, issuedAt time.Time) (*registry.Registry, *registry.Provider, registry.AppAttestServingAuthorization, *appAttestTestClock) {
	t.Helper()
	clock := &appAttestTestClock{}
	clock.Store(issuedAt.Add(time.Second).UnixNano())
	r := registry.NewWithDependencies(testLogger(), registry.Dependencies{AppAttestNow: clock.Now})
	r, p, lease := appAttestTestProvider(t, r)
	p.ModelAutopilot = rewardConsentState()
	p.ModelAutopilot.Enabled = true
	p.ModelAutopilot.SelectedModels = []string{appAttestTestModel, "second-model"}
	p.Models = []protocol.ModelInfo{{ID: appAttestTestModel, WeightHash: "first"}, {ID: "second-model", WeightHash: "second"}}
	r.SetModelCatalog([]registry.CatalogEntry{{ID: appAttestTestModel, WeightHash: "first"}, {ID: "second-model", WeightHash: "second"}})
	lease.IssuedAt, lease.ValidUntil, lease.OSVersion = issuedAt, issuedAt.Add(time.Minute), "27.0"
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant receipt authorization")
	}
	return r, p, lease, clock
}

func TestAutopilotRewardAuthorizationMustExistAtDeclarationTime(t *testing.T) {
	midnight := time.Date(2026, time.October, 9, 0, 0, 0, 0, time.UTC)
	received := midnight.Add(-200 * time.Millisecond)
	r, p, lease, _ := rewardReceiptAuthorization(t, midnight.Add(200*time.Millisecond))
	declaration := r.AutopilotRewardDeclarationAt(p, received)
	if declaration.Qualified || !declaration.OptedIn || !declaration.Supported || !declaration.At.Equal(received) {
		t.Fatalf("receipt %s used authorization first issued %s: %+v", received, lease.IssuedAt, declaration)
	}
	if !r.AutopilotRewardDeclaration(p).Qualified {
		t.Fatal("fixture is not qualified at processing time")
	}
}

func TestAutopilotRewardAuthorizationUsesReceiptIntervalBoundaries(t *testing.T) {
	issued := time.Date(2026, time.October, 8, 12, 0, 0, 0, time.UTC)
	r, p, lease, clock := rewardReceiptAuthorization(t, issued)
	// Processing after expiry must not erase eligibility earned by a frame
	// received during the lease. The inspection clock still sees expiry.
	clock.Store(lease.ValidUntil.Add(time.Second).UnixNano())
	for _, tc := range []struct {
		name string
		at   time.Time
		want bool
	}{
		{"before_issued", issued.Add(-time.Nanosecond), false},
		{"issued_inclusive", issued, true},
		{"last_valid_instant", lease.ValidUntil.Add(-time.Nanosecond), true},
		{"valid_until_exclusive", lease.ValidUntil, false},
		{"after_expiry", lease.ValidUntil.Add(time.Nanosecond), false},
		{"missing_receipt", time.Time{}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			declaration := r.AutopilotRewardDeclarationAt(p, tc.at)
			if declaration.Qualified != tc.want || !declaration.OptedIn || !declaration.At.Equal(tc.at) {
				t.Fatalf("receipt qualification = %+v, want qualified=%v", declaration, tc.want)
			}
		})
	}
	if r.AutopilotRewardDeclaration(p).Qualified {
		t.Fatal("current inspection ignored its expired lease clock")
	}
}

func TestAutopilotRewardReceiptKeepsCurrentSecurityAndPrivacyGates(t *testing.T) {
	issued := time.Date(2026, time.October, 8, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name   string
		change func(*registry.Registry, *registry.Provider, registry.AppAttestServingAuthorization)
	}{
		{"revoked", func(r *registry.Registry, _ *registry.Provider, lease registry.AppAttestServingAuthorization) {
			r.RevokeAppAttestCredential(lease.CredentialID)
		}},
		{"denied", func(r *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			r.MarkUntrusted(p.ID)
		}},
		{"changed_policy", func(r *registry.Registry, _ *registry.Provider, _ registry.AppAttestServingAuthorization) {
			r.SetAppAttestServingPolicy(true, 8)
		}},
		{"changed_endpoint", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.PublicKey = "new-endpoint"
		}},
		{"changed_account", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.AccountID = "new-owner"
		}},
		{"changed_hardware", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.Hardware.MemoryGB++
		}},
		{"runtime_unverified", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.RuntimeVerified = false
		}},
		{"manifest_unverified", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.RuntimeManifestChecked = false
		}},
		{"privacy_disabled", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.PrivacyCapabilities.EnvScrubbed = false
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, p, lease, _ := rewardReceiptAuthorization(t, issued)
			received := issued.Add(time.Second)
			if !r.AutopilotRewardDeclarationAt(p, received).Qualified {
				t.Fatal("fixture receipt was not qualified")
			}
			tc.change(r, p, lease)
			if declaration := r.AutopilotRewardDeclarationAt(p, received); declaration.Qualified || !declaration.OptedIn {
				t.Fatalf("historical receipt bypassed current denial or erased consent: %+v", declaration)
			}
		})
	}
}

func TestAutopilotRewardReceiptUsesAuthorizationTimeForModelCapabilities(t *testing.T) {
	issued := time.Date(2026, time.October, 8, 12, 0, 0, 0, time.UTC)
	r, p, lease, clock := rewardReceiptAuthorization(t, issued)
	p.Hardware.ChipFamily = "M5"
	p.ReportedRuntimeCapabilities = []string{registry.ProviderCapabilityAppleM5}
	p.AttestationResult = &attestation.VerificationResult{Valid: true, ChipFamily: "M5", RuntimeCapabilities: p.ReportedRuntimeCapabilities}
	if err := r.ReconcileAttestedRuntimeCapabilities(p.ID); err != nil {
		t.Fatal(err)
	}
	r.SetModelCatalog([]registry.CatalogEntry{
		{ID: appAttestTestModel, WeightHash: "first"},
		{ID: "second-model", WeightHash: "second", RequiredProviderCapabilities: []string{registry.ProviderCapabilityAppleM5}},
	})
	clock.Store(lease.ValidUntil.Add(time.Second).UnixNano())
	if declaration := r.AutopilotRewardDeclarationAt(p, issued.Add(time.Second)); !declaration.Qualified {
		t.Fatalf("processing-time expiry hid receipt-time authenticated capability: %+v", declaration)
	}
	if r.AutopilotRewardDeclaration(p).Qualified {
		t.Fatal("expired inspection retained capability qualification")
	}
}
