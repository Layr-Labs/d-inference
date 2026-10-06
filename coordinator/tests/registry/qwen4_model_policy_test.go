package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestQwen4CatalogIdentityRequiresCompatibleProvider(t *testing.T) {
	const model = "qwen3.8-flash-next"
	for _, test := range []struct {
		version string
		allowed bool
	}{
		{"", false}, {"invalid", false}, {"0.9.4", false}, {"0.9.5-rc1", false},
		{"0.9.5", false}, {"v0.9.5", false}, {"0.9.6-rc1", false},
		{"0.9.6", true}, {"v0.9.6", true}, {"0.10.0", true},
	} {
		r := production.New(testLogger())
		msg := testRegisterMessage()
		msg.Version = test.version
		msg.Models = []protocol.ModelInfo{{ID: model}}
		p := r.Register("p", nil, msg)
		p.SetVersion(msg.Version)
		makeProviderRoutable(p)
		for _, traits := range []production.RequestTraits{{}, {HasTools: true}, {HasTools: true, ToolChoiceMode: "none"}} {
			if got := r.HasToolCapableProviderForTraits(model, traits); got != test.allowed {
				t.Fatalf("version=%q traits=%+v got=%v want=%v", test.version, traits, got, test.allowed)
			}
		}
	}
}

func TestQwen4CatalogFloorDoesNotChangeOtherIdentities(t *testing.T) {
	for _, model := range []string{"DarkBloom/Qwen3.8-Flash-Next-Q4-mtp", "qwen3.8-flash-next-other", "QWEN3.8-FLASH-NEXT", "gemma-4-26b", "gpt-oss-20b", "nvidia-nemotron-3.5-lightning"} {
		r := production.New(testLogger())
		msg := testRegisterMessage()
		msg.Models = []protocol.ModelInfo{{ID: model}}
		makeProviderRoutable(r.Register("p", nil, msg))
		if !r.HasToolCapableProviderForTraits(model, production.RequestTraits{}) {
			t.Fatalf("unrelated/legacy identity unexpectedly gated: %q", model)
		}
	}
}
