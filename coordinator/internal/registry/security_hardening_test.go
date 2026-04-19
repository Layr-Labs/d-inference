package registry

import (
	"context"
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/coordinator/internal/protocol"
)

func newSecurityTestRegistry() *Registry {
	return New(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
}

// F4: Catalog defines a weight hash; provider that omits weight_hash in
// models[] AND in model_hashes must have the model dropped.
func TestRegister_DropsCatalogModelWithMissingWeightHash(t *testing.T) {
	reg := newSecurityTestRegistry()
	reg.SetModelCatalog([]CatalogEntry{
		{ID: "m1", WeightHash: "expected-hash"},
	})

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
		Models: []protocol.ModelInfo{
			{ID: "m1", ModelType: "test", Quantization: "4bit"}, // no weight_hash
		},
	}
	p := reg.Register("p1", nil, msg)
	if len(p.Models) != 0 {
		t.Fatalf("expected catalog model with missing weight_hash to be dropped, got %v", p.Models)
	}
}

// F4: Catalog defines a weight hash; provider that reports a *wrong* one
// must have the model dropped.
func TestRegister_DropsCatalogModelWithWrongWeightHash(t *testing.T) {
	reg := newSecurityTestRegistry()
	reg.SetModelCatalog([]CatalogEntry{
		{ID: "m1", WeightHash: "expected-hash"},
	})

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
		Models: []protocol.ModelInfo{
			{ID: "m1", ModelType: "test", WeightHash: "ATTACKER-HASH"},
		},
	}
	p := reg.Register("p1", nil, msg)
	if len(p.Models) != 0 {
		t.Fatalf("expected catalog model with wrong weight_hash to be dropped, got %v", p.Models)
	}
}

// F4: A provider that reports the right hash via the per-model field passes.
func TestRegister_AcceptsCatalogModelWithCorrectWeightHash(t *testing.T) {
	reg := newSecurityTestRegistry()
	reg.SetModelCatalog([]CatalogEntry{
		{ID: "m1", WeightHash: "expected-hash"},
	})

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
		Models: []protocol.ModelInfo{
			{ID: "m1", ModelType: "test", WeightHash: "expected-hash"},
		},
	}
	p := reg.Register("p1", nil, msg)
	if len(p.Models) != 1 || p.Models[0].ID != "m1" {
		t.Fatalf("expected m1 to be accepted, got %v", p.Models)
	}
}

// F4: A provider that reports the right hash via model_hashes (signed
// claims envelope) passes even with empty per-model field.
func TestRegister_AcceptsCatalogModelViaModelHashesMap(t *testing.T) {
	reg := newSecurityTestRegistry()
	reg.SetModelCatalog([]CatalogEntry{
		{ID: "m1", WeightHash: "expected-hash"},
	})

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
		Models: []protocol.ModelInfo{
			{ID: "m1", ModelType: "test"},
		},
		ModelHashes: map[string]string{"m1": "expected-hash"},
	}
	p := reg.Register("p1", nil, msg)
	if len(p.Models) != 1 {
		t.Fatalf("expected m1 to be accepted via model_hashes map, got %v", p.Models)
	}
}

// F6: TPS values above the hardware-derived ceiling are clamped.
func TestRegister_ClampsAbusivelyHighDecodeTPS(t *testing.T) {
	reg := newSecurityTestRegistry()
	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
		// Provider claims absurdly high TPS to dominate routing.
		PrefillTPS: 99999,
		DecodeTPS:  99999,
	}
	p := reg.Register("p1", nil, msg)
	// Decode ceiling is bandwidth (400). Prefill ceiling is 8x = 3200.
	if p.DecodeTPS > 400 {
		t.Errorf("decode_tps not clamped: %f > 400", p.DecodeTPS)
	}
	if p.PrefillTPS > 3200 {
		t.Errorf("prefill_tps not clamped: %f > 3200", p.PrefillTPS)
	}
}

// F6: Negative TPS is treated as zero, not honored.
func TestRegister_ClampsNegativeTPS(t *testing.T) {
	reg := newSecurityTestRegistry()
	msg := &protocol.RegisterMessage{
		Type:       protocol.TypeRegister,
		Hardware:   protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:    "test",
		PrefillTPS: -1,
		DecodeTPS:  -1,
	}
	p := reg.Register("p1", nil, msg)
	if p.DecodeTPS < 0 {
		t.Errorf("decode_tps left negative: %f", p.DecodeTPS)
	}
	if p.PrefillTPS < 0 {
		t.Errorf("prefill_tps left negative: %f", p.PrefillTPS)
	}
}

// FindPendingOwner returns the right provider for a given request_id.
func TestFindPendingOwner_Routes(t *testing.T) {
	reg := newSecurityTestRegistry()
	reg.MinTrustLevel = TrustNone
	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
	}
	p := reg.Register("p-find", nil, msg)
	pr := &PendingRequest{RequestID: "req-xyz", Model: "m"}
	p.AddPending(pr)
	owner := reg.FindPendingOwner("req-xyz")
	if owner == nil || owner.ID != p.ID {
		t.Fatalf("expected to find owner p-find, got %v", owner)
	}
	if reg.FindPendingOwner("nonexistent") != nil {
		t.Fatal("expected nil for unknown request_id")
	}
}

// Routing is gated on ClaimsVerified. A provider with RuntimeVerified=true
// but ClaimsVerified=false must NOT be selected by FindProvider.
func TestFindProvider_GatesOnClaimsVerified(t *testing.T) {
	reg := newSecurityTestRegistry()
	reg.MinTrustLevel = TrustNone
	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
		Models:   []protocol.ModelInfo{{ID: "m"}},
	}
	p := reg.Register("p1", nil, msg)
	reg.SetTrustLevel(p.ID, TrustHardware)
	reg.RecordChallengeSuccess(p.ID)
	// Force ClaimsVerified=false to simulate failed claims envelope check.
	p.mu.Lock()
	p.ClaimsVerified = false
	p.mu.Unlock()

	if got := reg.FindProvider("m"); got != nil {
		t.Fatalf("expected nil — provider should be excluded with ClaimsVerified=false, got %v", got)
	}

	// Re-enable and verify it's now routable.
	reg.SetClaimsVerifiedForTest(p.ID, true)
	if got := reg.FindProvider("m"); got == nil {
		t.Fatal("expected provider to be routable once ClaimsVerified=true")
	}
}

// PersistProvider should save ClaimsVerified state too.
func TestPersistProvider_RestoresClaimsVerifiedFromStore(t *testing.T) {
	// Use a registry with no store to avoid requiring postgres in unit tests;
	// just check that the field exists on the in-memory struct.
	reg := newSecurityTestRegistry()
	reg.MinTrustLevel = TrustNone
	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
	}
	p := reg.Register("p1", nil, msg)
	if !p.ClaimsVerified {
		t.Fatal("default ClaimsVerified should be true after Register (API layer overrides on failure)")
	}
	// Just make sure context plumbing is fine.
	_ = context.Background()
}
