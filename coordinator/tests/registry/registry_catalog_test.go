package registry_test

import (
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestModelCatalogWeightHashVerification(t *testing.T) {
	reg := production.New(testLogger())
	reg.MinTrustLevel = production.TrustNone

	correctHash := "abc123def456"
	wrongHash := "ffffffffffffffff"

	// Catalog requires a specific weight hash.
	reg.SetModelCatalog([]production.CatalogEntry{
		{ID: "model-a", WeightHash: correctHash},
		{ID: "model-b"}, // no hash enforcement
	})

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: testRegisterMessage().Hardware,
		Models: []protocol.ModelInfo{
			{ID: "model-a", SizeBytes: 1000, WeightHash: correctHash}, // correct
			{ID: "model-b", SizeBytes: 2000, WeightHash: "anything"},  // no enforcement
		},
		Backend: "vllm_mlx",
	}
	p := reg.Register("p1", nil, msg)

	if len(p.Models) != 2 {
		t.Fatalf("expected 2 models (both valid), got %d", len(p.Models))
	}

	// Now try with wrong hash for model-a.
	msg2 := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: testRegisterMessage().Hardware,
		Models: []protocol.ModelInfo{
			{ID: "model-a", SizeBytes: 1000, WeightHash: wrongHash}, // mismatch
			{ID: "model-b", SizeBytes: 2000, WeightHash: "anything"},
		},
		Backend: "vllm_mlx",
	}
	p2 := reg.Register("p2", nil, msg2)

	if len(p2.Models) != 2 {
		t.Fatalf("expected full provider inventory to be preserved, got %d", len(p2.Models))
	}
	models := reg.PublicProviderModels()[p2.ID].Models
	modelAAllowed := slices.Contains(models, "model-a")
	modelBAllowed := slices.Contains(models, "model-b")
	if modelAAllowed {
		t.Fatal("expected model-a with wrong hash to be unroutable")
	}
	if !modelBAllowed {
		t.Fatal("expected model-b to remain allowed")
	}
}

func TestModelCatalogGatesRoutingWithoutDroppingInventory(t *testing.T) {
	reg := production.New(testLogger())
	reg.MinTrustLevel = production.TrustNone

	// Set catalog: only one model is whitelisted.
	reg.SetModelCatalog([]production.CatalogEntry{{ID: "mlx-community/Qwen3.5-9B-Instruct-4bit"}})

	// Register a provider with two models — one in catalog, one not.
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{
		{ID: "mlx-community/Qwen3.5-9B-Instruct-4bit", SizeBytes: 5700000000, ModelType: "qwen3", Quantization: "4bit"},
		{ID: "mlx-community/random-model-not-in-catalog", SizeBytes: 1000000, ModelType: "llama", Quantization: "4bit"},
	}
	p := reg.Register("p1", nil, msg)

	if len(p.Models) != 2 {
		t.Fatalf("expected full provider inventory to be preserved, got %d models", len(p.Models))
	}
	testMakeTextRoutable(p)
	if found := findRoutableProvider(reg, "mlx-community/random-model-not-in-catalog"); found != nil {
		t.Fatal("expected non-catalog model to stay unroutable")
	}
	if found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit"); found == nil {
		t.Fatal("expected catalog model to be routable")
	}
}

func TestModelCatalogFilterOnRegisterNoCatalog(t *testing.T) {
	reg := production.New(testLogger())
	reg.MinTrustLevel = production.TrustNone

	// No catalog set — all models should be accepted.
	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: testRegisterMessage().Hardware,
		Models: []protocol.ModelInfo{
			{ID: "model-a", SizeBytes: 1000, ModelType: "llama", Quantization: "4bit"},
			{ID: "model-b", SizeBytes: 2000, ModelType: "qwen2", Quantization: "8bit"},
		},
		Backend: "vllm_mlx",
	}
	p := reg.Register("p1", nil, msg)

	if len(p.Models) != 2 {
		t.Fatalf("expected 2 models without catalog, got %d", len(p.Models))
	}
}

func TestIsModelInCatalog(t *testing.T) {
	reg := production.New(testLogger())

	// No catalog — everything is allowed.
	if !reg.IsModelInCatalog("any-model") {
		t.Error("expected IsModelInCatalog to return true with no catalog set")
	}

	// Set catalog.
	reg.SetModelCatalog([]production.CatalogEntry{{ID: "model-a"}, {ID: "model-b"}})

	if !reg.IsModelInCatalog("model-a") {
		t.Error("expected model-a to be in catalog")
	}
	if !reg.IsModelInCatalog("model-b") {
		t.Error("expected model-b to be in catalog")
	}
	if reg.IsModelInCatalog("model-c") {
		t.Error("expected model-c to NOT be in catalog")
	}

	// Empty but configured catalog means deny-all. This is the production
	// startup state for a fresh DB-backed model registry with no promoted rows.
	reg.SetModelCatalog([]production.CatalogEntry{})
	if reg.IsModelInCatalog("model-a") {
		t.Error("expected configured empty catalog to deny all models")
	}

	// Clear catalog.
	reg.SetModelCatalog(nil)
	if !reg.IsModelInCatalog("model-c") {
		t.Error("expected IsModelInCatalog to return true after clearing catalog")
	}
}

func TestRegisterWithEmptyConfiguredCatalogPreservesInventoryButRoutesNothingUntilCatalogUpdates(t *testing.T) {
	reg := production.New(testLogger())
	reg.MinTrustLevel = production.TrustNone
	reg.SetModelCatalog([]production.CatalogEntry{})

	provider := reg.Register("p-empty-catalog", nil, testRegisterMessage())
	if len(provider.Models) != 1 {
		t.Fatalf("expected provider inventory to be preserved, got %#v", provider.Models)
	}
	testMakeTextRoutable(provider)
	modelID := provider.Models[0].ID
	if found := findRoutableProvider(reg, modelID); found != nil {
		t.Fatal("expected empty configured catalog to route no models")
	}
	reg.SetModelCatalog([]production.CatalogEntry{{ID: modelID}})
	if found := findRoutableProvider(reg, modelID); found == nil {
		t.Fatal("expected existing provider to become routable after catalog update")
	}
}

func TestFindProviderRespectsModelCatalog(t *testing.T) {
	reg := production.New(testLogger())
	reg.MinTrustLevel = production.TrustNone

	// Register a provider with a model NOT in catalog.
	reg.SetModelCatalog([]production.CatalogEntry{{ID: "whitelisted-model"}})

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: testRegisterMessage().Hardware,
		Models: []protocol.ModelInfo{
			{ID: "not-whitelisted", SizeBytes: 1000},
		},
		Backend: "vllm_mlx",
	}
	p := reg.Register("p1", nil, msg)
	p.Mu().Lock()
	p.LastChallengeVerified = time.Now()
	p.Mu().Unlock()

	// Provider's model was filtered at registration — FindProvider won't find it.
	found := findRoutableProvider(reg, "not-whitelisted")
	if found != nil {
		t.Error("expected FindProvider to return nil for non-catalog model")
	}

	// The whitelisted model has no provider either.
	found = findRoutableProvider(reg, "whitelisted-model")
	if found != nil {
		t.Error("expected FindProvider to return nil when no provider has the model")
	}
}

// TestDesiredModelsForLegacyAdvertiserAfterTakeover proves the 4-bit cutover
// bootstrap: after an alias adopts the live public name (desired = new build,
// previous = the legacy same-named build), a provider advertising ONLY the legacy
// build is recognised as a member and told to converge to the new build via
// desired_models without which the legacy fleet could never migrate.
func TestDesiredModelsForLegacyAdvertiserAfterTakeover(t *testing.T) {
	r := production.New(testLogger())
	r.Register("p1", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "gemma-4-26b"}}, // advertises the public name
	})
	r.SetModelAliases(map[string]production.AliasTarget{
		"gemma-4-26b": {Desired: "gemma-4-26b-qat-4bit", Previous: "gemma-4-26b"},
	})

	entries := r.DesiredModelsForProvider("p1")
	if len(entries) != 1 {
		t.Fatalf("expected 1 desired_models entry for the legacy advertiser, got %d", len(entries))
	}
	if entries[0].ModelName != "gemma-4-26b" || entries[0].DesiredBuild != "gemma-4-26b-qat-4bit" {
		t.Fatalf("unexpected desired entry: %+v", entries[0])
	}
	if entries[0].PreviousBuild != "gemma-4-26b" {
		t.Fatalf("expected previous build = legacy id, got %q", entries[0].PreviousBuild)
	}
}

func TestCatalogWeightHash(t *testing.T) {
	reg := production.New(testLogger())

	// No catalog — empty hash.
	if h := reg.CatalogWeightHash("any"); h != "" {
		t.Errorf("expected empty hash with no catalog, got %q", h)
	}

	reg.SetModelCatalog([]production.CatalogEntry{
		{ID: "model-a", WeightHash: "hash123"},
		{ID: "model-b"},
	})

	if h := reg.CatalogWeightHash("model-a"); h != "hash123" {
		t.Errorf("expected hash123, got %q", h)
	}
	if h := reg.CatalogWeightHash("model-b"); h != "" {
		t.Errorf("expected empty hash for model-b, got %q", h)
	}
	if h := reg.CatalogWeightHash("model-c"); h != "" {
		t.Errorf("expected empty hash for unknown model, got %q", h)
	}
}
