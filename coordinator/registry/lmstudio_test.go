package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestReplaceLMStudioModelsIsAuthoritativeAndPreservesNativeModels(t *testing.T) {
	r := New(testLogger())
	p := &Provider{
		ID:        "provider",
		AccountID: "owner",
		Models:    []protocol.ModelInfo{{ID: "native"}, {ID: "lmstudio/old"}},
	}
	r.providers[p.ID] = p

	added, removed := r.ReplaceLMStudioModels(p.ID, []protocol.ModelInfo{
		{ID: "lmstudio/laguna", ModelType: "chat"},
		{ID: "not-namespaced"},
		{ID: "lmstudio/laguna"},
	})

	if len(added) != 1 || added[0] != "lmstudio/laguna" {
		t.Fatalf("added = %v", added)
	}
	if len(removed) != 1 || removed[0] != "lmstudio/old" {
		t.Fatalf("removed = %v", removed)
	}
	if len(p.Models) != 2 || p.Models[0].ID != "native" || p.Models[1].ID != "lmstudio/laguna" {
		t.Fatalf("models = %+v", p.Models)
	}

	_, removed = r.ReplaceLMStudioModels(p.ID, nil)
	if len(removed) != 1 || removed[0] != "lmstudio/laguna" || len(p.Models) != 1 || p.Models[0].ID != "native" {
		t.Fatalf("empty replacement: removed=%v models=%+v", removed, p.Models)
	}
}

func TestReplaceLMStudioModelsRequiresLinkedProvider(t *testing.T) {
	r := New(testLogger())
	p := &Provider{ID: "provider", Models: []protocol.ModelInfo{{ID: "native"}}}
	r.providers[p.ID] = p

	added, removed := r.ReplaceLMStudioModels(p.ID, []protocol.ModelInfo{{ID: "lmstudio/laguna"}})
	if len(added) != 0 || len(removed) != 0 || len(p.Models) != 1 {
		t.Fatalf("unlinked provider mutated: added=%v removed=%v models=%+v", added, removed, p.Models)
	}
}

func TestLMStudioNamespaceIsNeverPubliclyRoutable(t *testing.T) {
	r := New(testLogger())
	p := &Provider{Models: []protocol.ModelInfo{{ID: "lmstudio/laguna"}}}

	r.mu.RLock()
	p.mu.Lock()
	public := r.providerServesRoutableModelLocked(p, "lmstudio/laguna", false)
	owner := r.providerServesRoutableModelLocked(p, "lmstudio/laguna", true)
	p.mu.Unlock()
	r.mu.RUnlock()

	if public {
		t.Fatal("LM Studio model became public fleet capacity")
	}
	if !owner {
		t.Fatal("LM Studio model should remain available to owner self-route")
	}
}
