package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"testing"
	"time"
)

func TestSystemOneCapabilityFencesAndBudget(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: "laya", SystemOne: true}, {ID: "chat"}})
	for _, tc := range []struct {
		name, model, kind  string
		flag, native, want bool
	}{
		{"native advertised", "laya", "laya", true, true, true},
		{"old provider", "laya", "laya", false, true, false},
		{"wrong runtime", "laya", "chat", true, true, false},
		{"generation on native", "laya", "laya", true, false, false},
		{"provider cannot change catalog endpoint", "chat", "laya", true, true, false},
		{"chat unchanged", "chat", "chat", false, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := &Provider{Models: []protocol.ModelInfo{{ID: tc.model, ModelType: tc.kind, SystemOne: tc.flag, TemplateRenderOK: boolPtr(false)}}}
			// Native requests never render chat templates; ordinary chat still does.
			if !tc.native {
				p.Models[0].TemplateRenderOK = nil
			}
			reg.mu.RLock()
			p.mu.Lock()
			got := reg.providerEligibleForTraitsLocked(p, tc.model, RequestTraits{SystemOne: tc.native})
			p.mu.Unlock()
			reg.mu.RUnlock()
			if got != tc.want {
				t.Fatalf("eligibility %v want %v", got, tc.want)
			}
		})
	}
	pr := &PendingRequest{EstimatedPromptTokens: 512, Traits: RequestTraits{SystemOne: true}}
	if got := pendingTokenBudget(pr); got != 512 {
		t.Fatalf("native reserved output tokens: %d", got)
	}
	if _, out := drainRequestSize(pr); out != 0 {
		t.Fatalf("queue inserted output budget %d", out)
	}
	pr.Traits.SystemOne = false
	if got := pendingTokenBudget(pr); got != 512+defaultRequestedMaxTokens {
		t.Fatalf("generation default changed: %d", got)
	}
	reg.SetModelAliases(map[string]AliasTarget{"laya-latest": {Desired: "laya"}})
	if !reg.IsSystemOneModel("laya-latest") || reg.IsSystemOneModel("chat") {
		t.Fatal("catalog alias endpoint incorrect")
	}
}

func TestSystemOneCapabilityUpdateRevokesRouting(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: "laya", SystemOne: true}})
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: "laya", ModelType: "laya", SystemOne: true}}
	provider := reg.Register("native", nil, msg)
	provider.mu.Lock()
	testMakeTextRoutable(provider)
	provider.mu.Unlock()
	if !reg.HasSystemOneProviderForRouting("laya", "", false, false) {
		t.Fatal("native provider not eligible")
	}
	reg.MergeProviderModels(provider.ID, []protocol.ModelInfo{{ID: "laya", ModelType: "laya"}})
	if reg.HasSystemOneProviderForRouting("laya", "", false, false) {
		t.Fatal("models_update could not revoke native capability")
	}
	reg.MergeProviderModels(provider.ID, []protocol.ModelInfo{{ID: "laya", ModelType: "laya", SystemOne: true}})
	if !reg.HasSystemOneProviderForRouting("laya", "", false, false) {
		t.Fatal("models_update could not enable native capability")
	}
	reg.Disconnect(provider.ID)
	if reg.HasSystemOneProviderForRouting("laya", "", false, false) {
		t.Fatal("disconnect retained native capability")
	}
}

func TestSystemOneNativeSlotSkipsDecodePredictionButEnforcesCapacityAndDeadline(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: "laya", SystemOne: true}})
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: "laya", ModelType: "laya", SystemOne: true}}
	p := reg.Register("native", nil, msg)
	p.mu.Lock()
	testMakeTextRoutable(p)
	p.DecodeTPS = 0
	p.PrefillTPS = 0
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: "laya", State: "idle", MaxConcurrency: 1, ActiveTokenBudgetMax: 32768, MaxTokensPotential: 0}}}
	p.mu.Unlock()
	pr := &PendingRequest{RequestID: "native-full", Model: "laya", Traits: RequestTraits{SystemOne: true}, EstimatedPromptTokens: 32768, RequestedMaxTokens: 0, MaxTTFTMs: 10000, FirstContentDeadline: time.Now().Add(10 * time.Second)}
	selected, decision := reg.ReserveProviderEx("laya", pr)
	if selected == nil || decision.TTFTRejections != 0 {
		t.Fatalf("native encoder rejected by decode predictor: %+v", decision)
	}
	second := &PendingRequest{RequestID: "native-busy", Model: "laya", Traits: RequestTraits{SystemOne: true}, EstimatedPromptTokens: 512}
	if got, decision := reg.ReserveProviderEx("laya", second); got != nil || decision.CapacityRejections == 0 {
		t.Fatalf("busy native slot admitted: %v %+v", got, decision)
	}
	p.RemovePending(pr.RequestID)
	reg.SetProviderIdle(p.ID)
	expired := &PendingRequest{RequestID: "native-expired", Model: "laya", Traits: RequestTraits{SystemOne: true}, EstimatedPromptTokens: 512, FirstContentDeadline: time.Now().Add(-time.Second)}
	if expired.RefreshFirstContentBudget(time.Now()) {
		t.Fatal("native deadline was waived")
	}
}

func TestSystemOneDoesNotPrepareLegacyCacheBuster(t *testing.T) {
	reg := New(testLogger())
	pr := &PendingRequest{RequestID: "native", Traits: RequestTraits{SystemOne: true}}
	if err := reg.PrepareCacheAttempt(pr, &Provider{PrefixCacheProtocol: 0}); err != nil {
		t.Fatal(err)
	}
	if pr.LegacyCacheBustKey != "" || pr.CacheRoutingParticipates() {
		t.Fatal("native request entered prompt cache protocol")
	}
}
