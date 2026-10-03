package trust

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
)

// TestBelowMinProviderVersion pins the floor predicate every gate shares
// (registration, challenge revalidation, manifest sync, release evidence).
func TestBelowMinProviderVersion(t *testing.T) {
	srv := &Owner{}
	for _, version := range []string{"", "0.1.0", "not-a-version"} {
		if srv.BelowMinProviderVersion(version) {
			t.Fatalf("no floor configured: version %q reported below it", version)
		}
	}

	srv.SetMinProviderVersion("0.9.5")
	cases := map[string]bool{
		"":              true,
		"0.9.4":         true,
		"not-a-version": true,
		"0.9.5":         false,
		"0.9.10":        false,
		"1.0.0":         false,
	}
	for version, want := range cases {
		if got := srv.BelowMinProviderVersion(version); got != want {
			t.Errorf("belowMinProviderVersion(%q) with floor 0.9.5 = %v, want %v", version, got, want)
		}
	}
}

// TestApplyChallengeMinVersionPolicyRejectsMissingVersion: challenge
// revalidation applies the same floor, so a version-less provider is derouted
// there too rather than keeping registration-time runtime state.
func TestApplyChallengeMinVersionPolicyRejectsMissingVersion(t *testing.T) {
	srv := &Owner{}
	srv.SetMinProviderVersion("0.9.5")
	provider := &registry.Provider{
		RuntimeVerified:        true,
		RuntimeManifestChecked: true,
		MetallibVerified:       true,
	}
	if _, allowed := srv.applyChallengeMinVersionPolicy(provider); allowed {
		t.Fatal("version-less provider passed challenge revalidation under floor 0.9.5")
	}
	if provider.RuntimeVerified || provider.RuntimeManifestChecked || provider.MetallibVerified {
		t.Fatal("rejected provider kept policy-derived runtime state")
	}

	provider.Version = "0.9.5"
	if _, allowed := srv.applyChallengeMinVersionPolicy(provider); !allowed {
		t.Fatal("provider at the floor failed challenge revalidation")
	}
}
