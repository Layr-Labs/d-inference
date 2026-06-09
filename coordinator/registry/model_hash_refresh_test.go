package registry

// Tests for UpdateModelWeightHashes — the coordinator half of the stale
// model-hash fix. Providers recompute weight hashes when a model is (re)loaded
// from disk (e.g. after a model re-publish); the registry must refresh its
// stored per-model hashes from the verified challenge response or the
// per-model catalog filter keeps judging the provider by its
// registration-time snapshot until the next reconnect.

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func registerWithWeightHash(reg *Registry, id, modelID, hash string) *Provider {
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{
		ID:           modelID,
		SizeBytes:    1000,
		ModelType:    "chat",
		Quantization: "4bit",
		WeightHash:   hash,
	}}
	return reg.Register(id, nil, msg)
}

func TestUpdateModelWeightHashesRefreshesStoredHash(t *testing.T) {
	reg := New(testLogger())
	registerWithWeightHash(reg, "p1", "gemma-test", "stale-hash")

	reg.UpdateModelWeightHashes("p1", map[string]string{"gemma-test": "fresh-hash"})

	p := reg.GetProvider("p1")
	if p == nil {
		t.Fatal("provider not found")
	}
	if got := p.Models[0].WeightHash; got != "fresh-hash" {
		t.Errorf("stored weight hash = %q, want %q", got, "fresh-hash")
	}
}

func TestUpdateModelWeightHashesIgnoresUnknownModelAndEmptyHash(t *testing.T) {
	reg := New(testLogger())
	registerWithWeightHash(reg, "p1", "gemma-test", "stale-hash")

	// Hash for a model this provider does not advertise: must not be added.
	reg.UpdateModelWeightHashes("p1", map[string]string{"other-model": "x"})
	p := reg.GetProvider("p1")
	if len(p.Models) != 1 || p.Models[0].WeightHash != "stale-hash" {
		t.Errorf("unknown model must not change stored models: %+v", p.Models)
	}

	// Empty hash: ignored, stored value kept.
	reg.UpdateModelWeightHashes("p1", map[string]string{"gemma-test": ""})
	if got := reg.GetProvider("p1").Models[0].WeightHash; got != "stale-hash" {
		t.Errorf("empty hash must be ignored, got %q", got)
	}

	// Unknown provider / empty map: must not panic.
	reg.UpdateModelWeightHashes("nonexistent", map[string]string{"gemma-test": "x"})
	reg.UpdateModelWeightHashes("p1", nil)
}

func TestUpdateModelWeightHashesIsCopyOnWrite(t *testing.T) {
	reg := New(testLogger())
	registerWithWeightHash(reg, "p1", "gemma-test", "stale-hash")

	// A reader holding the pre-update slice must keep seeing consistent old
	// data — the update must swap the slice, never mutate it in place.
	before := reg.GetProvider("p1").Models

	reg.UpdateModelWeightHashes("p1", map[string]string{"gemma-test": "fresh-hash"})

	if before[0].WeightHash != "stale-hash" {
		t.Error("pre-update slice was mutated in place (not copy-on-write)")
	}
	if got := reg.GetProvider("p1").Models[0].WeightHash; got != "fresh-hash" {
		t.Errorf("stored weight hash = %q, want %q", got, "fresh-hash")
	}
}
