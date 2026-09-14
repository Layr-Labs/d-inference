package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestVisionRoutingHelpers covers the per-provider vision capability check and
// the fleet-level fail-fast query that gate image/video routing. With a nil
// catalog the catalog filter allows all, so the gate reduces to "advertises this
// model id with IsVision".
func TestVisionRoutingHelpers(t *testing.T) {
	r := New(testLogger())
	visProv := &Provider{
		ID:     "p-vis",
		Status: StatusOnline,
		Models: []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true}},
	}
	textProv := &Provider{
		ID:     "p-text",
		Status: StatusOnline,
		Models: []protocol.ModelInfo{{ID: "gemma-4-26b"}}, // text-only build of the same model
	}
	insertTestProvider(r, visProv)
	insertTestProvider(r, textProv)

	r.mu.RLock()
	visOK := r.providerServesVisionModelLocked(visProv, "gemma-4-26b", false)
	textOK := r.providerServesVisionModelLocked(textProv, "gemma-4-26b", false)
	r.mu.RUnlock()
	if !visOK {
		t.Fatal("vision provider should serve gemma-4-26b as vision-capable")
	}
	if textOK {
		t.Fatal("text-only provider must NOT be vision-capable for gemma-4-26b")
	}

	// With a catalog that excludes the model, the public gate closes but the
	// owner self-route context (allowOffCatalog) still accepts the provider's
	// advertised VLM build — otherwise an owned off-catalog VLM would pass the
	// routable gate and then be starved by the vision gate.
	r.SetModelCatalog([]CatalogEntry{{ID: "some-other-model"}})
	r.mu.RLock()
	publicOK := r.providerServesVisionModelLocked(visProv, "gemma-4-26b", false)
	ownerOK := r.providerServesVisionModelLocked(visProv, "gemma-4-26b", true)
	ownerTextOK := r.providerServesVisionModelLocked(textProv, "gemma-4-26b", true)
	r.mu.RUnlock()
	if publicOK {
		t.Fatal("off-catalog model must not be vision-routable in the public context")
	}
	if !ownerOK {
		t.Fatal("off-catalog advertised VLM must be vision-routable in the owner self-route context")
	}
	if ownerTextOK {
		t.Fatal("owner context must still require a vision-capable build")
	}

	// The owner context lifts catalog MEMBERSHIP only: a build the catalog
	// tracks must still pass the weight-hash gate, mirroring the routable
	// gate's tamper tripwire.
	visProv.Models = []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true, WeightHash: "tampered"}}
	r.SetModelCatalog([]CatalogEntry{{ID: "gemma-4-26b", WeightHash: "expected"}})
	r.mu.RLock()
	ownerHashMismatchOK := r.providerServesVisionModelLocked(visProv, "gemma-4-26b", true)
	r.mu.RUnlock()
	if ownerHashMismatchOK {
		t.Fatal("owner context must not admit a catalog VLM with a mismatched weight hash")
	}
	visProv.Models = []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true}}
	r.SetModelCatalog(nil)

	if !r.HasVisionProviderForModel("gemma-4-26b") {
		t.Fatal("fleet has a vision provider for gemma-4-26b")
	}
	if r.HasVisionProviderForModel("gpt-oss-20b") {
		t.Fatal("no vision provider advertises gpt-oss-20b")
	}

	// An untrusted/offline vision provider must not satisfy the fleet check.
	visProv.Status = StatusUntrusted
	if r.HasVisionProviderForModel("gemma-4-26b") {
		t.Fatal("an untrusted vision provider must not satisfy the fleet vision check")
	}
}
