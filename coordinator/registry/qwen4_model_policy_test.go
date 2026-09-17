package registry

import "testing"

func TestQwen4CatalogIdentityRequiresCompatibleProvider(t *testing.T) {
	r := &Registry{}
	for _, test := range []struct {
		version string
		allowed bool
	}{
		{"", false}, {"invalid", false}, {"0.9.5", false}, {"0.9.6-rc1", false},
		{"0.9.6", true}, {"v0.9.6", true}, {"0.10.0", true},
	} {
		p := &Provider{Version: test.version}
		for _, traits := range []RequestTraits{{}, {HasTools: true}, {HasTools: true, ToolChoiceMode: "none"}} {
			if got := r.providerEligibleForTraitsLocked(p, qwen4RegistryModelID, traits); got != test.allowed {
				t.Fatalf("version=%q traits=%+v got=%v want=%v", test.version, traits, got, test.allowed)
			}
		}
	}
}

func TestQwen4CatalogFloorDoesNotChangeOtherIdentities(t *testing.T) {
	p := &Provider{}
	for _, model := range []string{"DarkBloom/Qwen3.8-Flash-Next-Q4-mtp", "qwen3.8-flash-next-other", "QWEN3.8-FLASH-NEXT", "gemma-4-26b", "gpt-oss-20b", "nvidia-nemotron-3.5-lightning"} {
		if !providerMeetsQwen4CatalogPolicyLocked(p, model) {
			t.Fatalf("unrelated/legacy identity unexpectedly gated: %q", model)
		}
	}
}
