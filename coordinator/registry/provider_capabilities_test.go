package registry

import (
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const capabilityTestMetallibHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func capabilityTestRegister(model, chipFamily string, capabilities []string) *protocol.RegisterMessage {
	msg := testRegisterMessage()
	msg.Hardware.ChipFamily = chipFamily
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	msg.RuntimeCapabilities = capabilities
	msg.TemplateHashes = map[string]string{"mlx_metallib": capabilityTestMetallibHash}
	return msg
}

func attestCapabilityTestProvider(
	t *testing.T,
	reg *Registry,
	provider *Provider,
	chipFamily string,
	capabilities []string,
	metallibHash string,
) {
	t.Helper()
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid:               true,
		ChipFamily:          chipFamily,
		RuntimeCapabilities: append([]string(nil), capabilities...),
		MetallibHash:        metallibHash,
	})
	provider.SetAttested(true, TrustHardware)
	provider.SetFreshCodeAttested()
	provider.mu.Lock()
	provider.RuntimeVerified = true
	provider.RuntimeManifestChecked = true
	provider.MetallibVerified = true
	provider.mu.Unlock()
	if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
		t.Fatalf("reconcile attested capabilities: %v", err)
	}
}

func TestRuntimeCapabilitiesRegisterCrossCheckAndHeartbeatCannotUpgrade(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: Qwen38NAXModelID}})
	msg := capabilityTestRegister(Qwen38NAXModelID, "M4", []string{
		ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX,
		ProviderCapabilityMLXNAX, " future_runtime ", "",
	})
	provider := reg.Register("old-provider", nil, msg)
	testMakeTextRoutable(provider)

	want := []string{"future_runtime", ProviderCapabilityMLXNAX}
	if !reflect.DeepEqual(provider.ReportedRuntimeCapabilities, want) {
		t.Fatalf("reported runtime capabilities = %v, want %v",
			provider.ReportedRuntimeCapabilities, want)
	}
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("unsigned outer claims became effective: %v", provider.RuntimeCapabilities)
	}
	if got := findRoutableProvider(reg, Qwen38NAXModelID); got != nil {
		t.Fatal("non-M5 provider routed protected model")
	}
	if merged, _ := reg.MergeProviderModels(provider.ID, []protocol.ModelInfo{{
		ID: Qwen38NAXModelID, ModelType: "chat",
	}}); len(merged) != 0 {
		t.Fatalf("models_update merged ineligible protected build: %v", merged)
	}

	active := Qwen38NAXModelID
	reg.Heartbeat(provider.ID, &protocol.HeartbeatMessage{
		Status:      "idle",
		ActiveModel: &active,
		WarmModels:  []string{Qwen38NAXModelID},
		BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
			Model: Qwen38NAXModelID, State: "idle",
		}}},
	})
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if len(provider.WarmModels) != 0 || provider.CurrentModel != "" ||
		provider.BackendCapacity == nil || len(provider.BackendCapacity.Slots) != 0 {
		t.Fatalf("heartbeat retained ineligible model state: warm=%v current=%q capacity=%+v",
			provider.WarmModels, provider.CurrentModel, provider.BackendCapacity)
	}
	if !reflect.DeepEqual(provider.ReportedRuntimeCapabilities, want) ||
		len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("heartbeat changed connection capabilities: reported=%v effective=%v",
			provider.ReportedRuntimeCapabilities, provider.RuntimeCapabilities)
	}
}

func TestProviderCapabilityRequirementsApplyToAliasAndSelfRoute(t *testing.T) {
	const previous = "compatible-previous"
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone
	reg.SetModelCatalog([]CatalogEntry{
		{ID: Qwen38NAXModelID},
		{ID: previous},
	})
	provider := reg.Register("owner", nil, capabilityTestRegister(
		Qwen38NAXModelID, "M4", nil))
	testMakeTextRoutable(provider)
	provider.mu.Lock()
	provider.AccountID = "account"
	provider.Models = append(provider.Models, protocol.ModelInfo{ID: previous, ModelType: "chat"})
	provider.mu.Unlock()
	reg.SetModelAliases(map[string]AliasTarget{"public": {
		Desired: Qwen38NAXModelID, Previous: previous,
	}})

	if findRoutableProvider(reg, Qwen38NAXModelID) != nil {
		t.Fatal("direct protected route used an ineligible provider")
	}
	if build, alias, ok := reg.ResolveModel("public"); !ok || !alias || build != previous {
		t.Fatalf("alias resolved to build=%q alias=%v ok=%v, want previous", build, alias, ok)
	}
	if build, alias, ok := reg.ResolveModelConstrained(
		"public", nil, "account", true, false,
	); !ok || !alias || build != previous {
		t.Fatalf("self-route alias resolved to build=%q alias=%v ok=%v, want previous", build, alias, ok)
	}
}

func TestProviderCapabilityEligibilityHotCatalogAndCommandDefenses(t *testing.T) {
	const ordinary = "ordinary-model"
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone
	reg.SetModelCatalog([]CatalogEntry{
		{ID: Qwen38NAXModelID},
		{ID: ordinary},
	})

	old := reg.Register("old", nil, capabilityTestRegister(
		Qwen38NAXModelID, "M4", nil))
	testMakeTextRoutable(old)
	old.AccountID = "owner"
	old.CurrentModel = Qwen38NAXModelID

	eligible := reg.Register("eligible", nil, capabilityTestRegister(
		Qwen38NAXModelID, "M5", []string{
			ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX,
		}))
	testMakeTextRoutable(eligible)
	attestCapabilityTestProvider(
		t,
		reg,
		eligible,
		"M5",
		[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
		capabilityTestMetallibHash,
	)
	eligible.CurrentModel = Qwen38NAXModelID

	if got := findRoutableProvider(reg, Qwen38NAXModelID); got == nil || got.ID != eligible.ID {
		t.Fatalf("protected model route = %#v, want eligible provider", got)
	}
	if models := reg.ListModels(); len(models) != 1 || models[0].Providers != 1 {
		t.Fatalf("public models exposed ineligible pair: %+v", models)
	}
	if snap := reg.ModelProviderSnapshot(); snap[Qwen38NAXModelID] != 1 {
		t.Fatalf("provider snapshot = %v, want one eligible pair", snap)
	}
	capacityFound := false
	for _, capacity := range reg.ModelCapacitySnapshot() {
		if capacity.ModelID == Qwen38NAXModelID {
			capacityFound = true
			if capacity.WarmProviders+capacity.ColdProviders != 1 {
				t.Fatalf("protected capacity counted ineligible provider: %+v", capacity)
			}
		}
	}
	if !capacityFound {
		t.Fatal("eligible protected model missing from capacity snapshot")
	}
	if providers := reg.ListProviders(); providers[0].ModelLoaded == providers[1].ModelLoaded {
		t.Fatalf("base-reward snapshots did not distinguish eligible loaded pair: %+v", providers)
	}

	reg.SetModelAliases(map[string]AliasTarget{"public": {
		Desired: Qwen38NAXModelID, Previous: ordinary,
	}})
	old.mu.Lock()
	old.Models = append(old.Models, protocol.ModelInfo{ID: ordinary, ModelType: "chat"})
	old.mu.Unlock()
	if entries := reg.DesiredModelsForProvider(old.ID); len(entries) != 0 {
		t.Fatalf("ineligible provider received desired protected build: %+v", entries)
	}

	loadCalls, prefetchCalls, desiredCalls := 0, 0, 0
	reg.loadModelSender = func(string, string) error { loadCalls++; return nil }
	reg.prefetchModelSender = func(string, string, int) error { prefetchCalls++; return nil }
	reg.desiredModelsSender = func(string, []protocol.DesiredModelEntry) error { desiredCalls++; return nil }
	entry := []protocol.DesiredModelEntry{{ModelName: "public", DesiredBuild: Qwen38NAXModelID}}
	if err := reg.SendLoadModel(old.ID, Qwen38NAXModelID); err == nil {
		t.Fatal("ineligible load_model succeeded")
	}
	if err := reg.SendPrefetchModel(old.ID, Qwen38NAXModelID, 1); err == nil {
		t.Fatal("ineligible prefetch_model succeeded")
	}
	if err := reg.SendDesiredModels(old.ID, entry); err == nil {
		t.Fatal("ineligible desired_models succeeded")
	}
	if loadCalls != 0 || prefetchCalls != 0 || desiredCalls != 0 {
		t.Fatalf("ineligible command invoked sender: load=%d prefetch=%d desired=%d",
			loadCalls, prefetchCalls, desiredCalls)
	}
	reserved := reg.reservePendingModelLoads([]modelLoadAction{{
		providerID: old.ID, modelID: Qwen38NAXModelID,
	}}, time.Now())
	if len(reserved) != 0 || reg.HasPendingModelLoad(old.ID, Qwen38NAXModelID) {
		t.Fatal("capability mismatch created a pending load")
	}
	reg.MarkModelWarm(old.ID, Qwen38NAXModelID)
	old.mu.Lock()
	if len(old.WarmModels) != 0 {
		t.Fatalf("MarkModelWarm accepted ineligible model: %v", old.WarmModels)
	}
	old.mu.Unlock()
	if got := reg.ColdSpillProviders(Qwen38NAXModelID, RequestTraits{}, false); got != 1 {
		t.Fatalf("cold candidates = %d, want only eligible provider", got)
	}

	fleet := reg.warmPoolFleetSnapshot(time.Now())[Qwen38NAXModelID]
	if len(fleet.eligibleCold) != 1 || fleet.eligibleCold[0].providerID != eligible.ID {
		t.Fatalf("warm-pool cold candidates = %+v, want only eligible provider", fleet.eligibleCold)
	}

	// A hot requirement change immediately hides an ordinary provider-model pair
	// while preserving its raw forensic inventory, then restores compatibility
	// when the unrelated model returns to its default empty requirement set.
	ordinaryProvider := reg.Register("ordinary", nil, capabilityTestRegister(ordinary, "M4", nil))
	testMakeTextRoutable(ordinaryProvider)
	if findRoutableProvider(reg, ordinary) == nil {
		t.Fatal("empty requirements broke unrelated model compatibility")
	}
	reg.SetModelCatalog([]CatalogEntry{{
		ID: ordinary, RequiredProviderCapabilities: []string{ProviderCapabilityAppleM5},
	}})
	if findRoutableProvider(reg, ordinary) != nil {
		t.Fatal("hot catalog requirement did not deroute provider")
	}
	if got := reg.ModelProviderSnapshot()[ordinary]; got != 0 {
		t.Fatalf("hot catalog provider snapshot count = %d", got)
	}
	ordinaryProvider.mu.Lock()
	inventoryPreserved := len(ordinaryProvider.Models) == 1 && ordinaryProvider.Models[0].ID == ordinary
	ordinaryProvider.mu.Unlock()
	if !inventoryPreserved {
		t.Fatal("hot catalog change destructively changed provider inventory")
	}
}

func TestAttestedRuntimeCapabilityReconciliationFailsClosed(t *testing.T) {
	newProvider := func(id string) (*Registry, *Provider) {
		reg := New(testLogger())
		provider := reg.Register(id, nil, capabilityTestRegister(
			Qwen38NAXModelID,
			"M5",
			[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
		))
		provider.mu.Lock()
		provider.RuntimeVerified = true
		provider.RuntimeManifestChecked = true
		provider.mu.Unlock()
		return reg, provider
	}

	t.Run("outer only forged claims", func(t *testing.T) {
		reg, provider := newProvider("outer-only")
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatal(err)
		}
		if len(provider.RuntimeCapabilities) != 0 {
			t.Fatalf("outer-only claims became effective: %v", provider.RuntimeCapabilities)
		}
	})

	t.Run("legacy signed payload", func(t *testing.T) {
		reg, provider := newProvider("legacy")
		provider.SetAttestationResult(&attestation.VerificationResult{Valid: true})
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatal(err)
		}
		if len(provider.RuntimeCapabilities) != 0 {
			t.Fatalf("legacy payload gained capabilities: %v", provider.RuntimeCapabilities)
		}
	})

	t.Run("signed capability mismatch", func(t *testing.T) {
		reg, provider := newProvider("cap-mismatch")
		provider.SetAttestationResult(&attestation.VerificationResult{
			Valid:               true,
			ChipFamily:          "M5",
			RuntimeCapabilities: []string{ProviderCapabilityAppleM5},
			MetallibHash:        capabilityTestMetallibHash,
		})
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err == nil {
			t.Fatal("signed capability mismatch was accepted")
		}
		if len(provider.RuntimeCapabilities) != 0 {
			t.Fatalf("mismatched signed claims became effective: %v", provider.RuntimeCapabilities)
		}
	})

	t.Run("signed metallib mismatch", func(t *testing.T) {
		reg, provider := newProvider("metallib-mismatch")
		provider.SetAttestationResult(&attestation.VerificationResult{
			Valid:               true,
			ChipFamily:          "M5",
			RuntimeCapabilities: []string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
			MetallibHash:        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		})
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err == nil {
			t.Fatal("signed metallib mismatch was accepted")
		}
		if len(provider.RuntimeCapabilities) != 0 {
			t.Fatalf("mismatched metallib claims became effective: %v", provider.RuntimeCapabilities)
		}
	})

	t.Run("cached code proof cannot promote protected capabilities", func(t *testing.T) {
		reg, provider := newProvider("reused-code-proof")
		provider.SetAttestationResult(&attestation.VerificationResult{
			Valid:               true,
			ChipFamily:          "M5",
			RuntimeCapabilities: []string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
			MetallibHash:        capabilityTestMetallibHash,
		})
		provider.SetAttested(true, TrustHardware)
		provider.SetCodeAttested(true) // cached/reused proof
		provider.mu.Lock()
		provider.MetallibVerified = true
		provider.mu.Unlock()
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatal(err)
		}
		if len(provider.RuntimeCapabilities) != 0 {
			t.Fatalf("reused code proof promoted protected capabilities: %v",
				provider.RuntimeCapabilities)
		}
		provider.SetFreshCodeAttested()
		if len(provider.RuntimeCapabilities) != 2 {
			t.Fatalf("fresh live proof did not promote capabilities: %v",
				provider.RuntimeCapabilities)
		}
	})

	t.Run("valid signed M5 NAX metallib", func(t *testing.T) {
		reg, provider := newProvider("valid")
		attestCapabilityTestProvider(
			t,
			reg,
			provider,
			"M5",
			[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
			capabilityTestMetallibHash,
		)
		want := []string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX}
		if !reflect.DeepEqual(provider.RuntimeCapabilities, want) {
			t.Fatalf("effective capabilities = %v, want %v",
				provider.RuntimeCapabilities, want)
		}
		provider.mu.Lock()
		provider.MetallibVerified = false
		provider.mu.Unlock()
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatal(err)
		}
		if len(provider.RuntimeCapabilities) != 0 {
			t.Fatalf("missing explicit metallib approval retained capabilities: %v",
				provider.RuntimeCapabilities)
		}
		provider.mu.Lock()
		provider.MetallibVerified = true
		provider.mu.Unlock()
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatal(err)
		}
		provider.mu.Lock()
		provider.Status = StatusServing
		provider.mu.Unlock()
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(provider.RuntimeCapabilities, want) {
			t.Fatalf("serving-state reconcile cleared capabilities: %v",
				provider.RuntimeCapabilities)
		}
		provider.mu.Lock()
		provider.Status = StatusOnline
		provider.mu.Unlock()
		provider.mu.Lock()
		provider.RuntimeManifestChecked = false
		provider.mu.Unlock()
		if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatal(err)
		}
		if len(provider.RuntimeCapabilities) != 0 {
			t.Fatalf("runtime-policy failure retained capabilities: %v",
				provider.RuntimeCapabilities)
		}
	})
}

func TestDuplicateRegisterCannotReplaceConnectionState(t *testing.T) {
	reg := New(testLogger())
	first := reg.Register("connection", nil, capabilityTestRegister(
		"ordinary-model", "M4", nil))
	firstCaps := append([]string(nil), first.ReportedRuntimeCapabilities...)

	second := reg.Register("connection", nil, capabilityTestRegister(
		Qwen38NAXModelID,
		"M5",
		[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
	))
	if second != first {
		t.Fatal("duplicate register replaced provider object")
	}
	if reg.ProviderCount() != 1 || reg.OnlineCount() != 1 {
		t.Fatalf("duplicate register changed counters: providers=%d online=%d",
			reg.ProviderCount(), reg.OnlineCount())
	}
	if !reflect.DeepEqual(first.ReportedRuntimeCapabilities, firstCaps) ||
		len(first.Models) != 1 || first.Models[0].ID != "ordinary-model" {
		t.Fatalf("duplicate register replaced state: caps=%v models=%v",
			first.ReportedRuntimeCapabilities, first.Models)
	}
	snapshot := reg.ModelProviderSnapshot()
	if snapshot["ordinary-model"] != 1 || snapshot[Qwen38NAXModelID] != 0 {
		t.Fatalf("duplicate register changed model counters: %v", snapshot)
	}

	reg.Disconnect(first.ID)
	reconnected := reg.Register("connection", nil, capabilityTestRegister(
		"reconnected-model", "M4", nil))
	if reconnected == first {
		t.Fatal("legitimate reconnect after disconnect reused stale provider")
	}
	if reg.ProviderCount() != 1 || reg.OnlineCount() != 1 {
		t.Fatalf("reconnect counters unstable: providers=%d online=%d",
			reg.ProviderCount(), reg.OnlineCount())
	}
}

func TestCapabilityPromotionRefreshesDesiredModelsOnce(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelAliases(map[string]AliasTarget{"protected": {
		Desired: Qwen38NAXModelID,
	}})
	provider := reg.Register("promotion", nil, capabilityTestRegister(
		Qwen38NAXModelID,
		"M5",
		[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
	))

	calls := 0
	var sent []protocol.DesiredModelEntry
	reg.desiredModelsSender = func(_ string, entries []protocol.DesiredModelEntry) error {
		calls++
		sent = append([]protocol.DesiredModelEntry(nil), entries...)
		return nil
	}
	reg.SetRuntimeCapabilitiesPromotedHook(func(providerID string) {
		_ = reg.SendDesiredModels(providerID, reg.DesiredModelsForProvider(providerID))
	})

	attestCapabilityTestProvider(
		t,
		reg,
		provider,
		"M5",
		[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
		capabilityTestMetallibHash,
	)
	if calls != 1 || len(sent) != 1 ||
		sent[0].DesiredBuild != Qwen38NAXModelID {
		t.Fatalf("promotion fanout calls=%d entries=%+v", calls, sent)
	}
	provider.SetCodeAttested(false)
	if calls != 2 || len(sent) != 0 {
		t.Fatalf("demotion did not send empty desired state: calls=%d entries=%+v",
			calls, sent)
	}
	provider.SetFreshCodeAttested()
	if calls != 3 || len(sent) != 1 ||
		sent[0].DesiredBuild != Qwen38NAXModelID {
		t.Fatalf("re-promotion did not resend desired state: calls=%d entries=%+v",
			calls, sent)
	}
	if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
		t.Fatal(err)
	}
	if calls != 3 {
		t.Fatalf("unchanged reconcile duplicated desired_models: calls=%d", calls)
	}
	testMakeTextRoutable(provider)
	reg.MarkUntrustedTransient(provider.ID)
	if calls != 4 || len(sent) != 0 {
		t.Fatalf("transient untrust did not send empty desired state: calls=%d entries=%+v",
			calls, sent)
	}
	if got := findRoutableProvider(reg, Qwen38NAXModelID); got != nil {
		t.Fatal("transiently untrusted provider remained routable")
	}
	reg.MarkUntrustedTransient(provider.ID)
	if calls != 4 {
		t.Fatalf("repeated transient untrust duplicated fanout: calls=%d", calls)
	}
	if !reg.RecordChallengeSuccess(provider.ID) {
		t.Fatal("passing challenge did not recover transient untrust")
	}
	if calls != 5 || len(sent) != 1 {
		t.Fatalf("transient recovery did not resend desired state: calls=%d entries=%+v",
			calls, sent)
	}

	reg.MarkUntrusted(provider.ID)
	if calls != 6 || len(sent) != 0 {
		t.Fatalf("hard untrust did not send empty desired state: calls=%d entries=%+v",
			calls, sent)
	}
	if got := findRoutableProvider(reg, Qwen38NAXModelID); got != nil {
		t.Fatal("hard-untrusted provider remained routable")
	}
	reg.MarkUntrusted(provider.ID)
	if calls != 6 {
		t.Fatalf("repeated hard untrust duplicated fanout: calls=%d", calls)
	}
}

func TestUntrustDesiredModelsWriteIsLinearizedAfterInFlightNonempty(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelAliases(map[string]AliasTarget{"protected": {
		Desired: Qwen38NAXModelID,
	}})
	provider := reg.Register("linearized", nil, capabilityTestRegister(
		Qwen38NAXModelID,
		"M5",
		[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
	))
	reg.desiredModelsSender = func(string, []protocol.DesiredModelEntry) error {
		return nil
	}
	reg.SetRuntimeCapabilitiesPromotedHook(func(providerID string) {
		_ = reg.SendDesiredModels(providerID, reg.DesiredModelsForProvider(providerID))
	})
	attestCapabilityTestProvider(
		t, reg, provider, "M5",
		[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
		capabilityTestMetallibHash,
	)

	provider.mu.Lock()
	provider.desiredModelsSent = false
	provider.lastDesiredModels = nil
	provider.mu.Unlock()

	started := make(chan struct{})
	release := make(chan struct{})
	var framesMu sync.Mutex
	var frames [][]protocol.DesiredModelEntry
	pauseNonempty := true
	reg.desiredModelsSender = func(
		_ string, entries []protocol.DesiredModelEntry,
	) error {
		if len(entries) > 0 && pauseNonempty {
			pauseNonempty = false
			close(started)
			<-release
		}
		framesMu.Lock()
		frames = append(frames, append([]protocol.DesiredModelEntry(nil), entries...))
		framesMu.Unlock()
		return nil
	}

	sendDone := make(chan error, 1)
	go func() {
		sendDone <- reg.SendDesiredModels(
			provider.ID, reg.DesiredModelsForProvider(provider.ID))
	}()
	<-started
	untrustDone := make(chan struct{})
	go func() {
		reg.MarkUntrustedTransient(provider.ID)
		close(untrustDone)
	}()
	close(release)
	if err := <-sendDone; err != nil {
		t.Fatal(err)
	}
	<-untrustDone

	// A later stale alias fanout is forced to empty and deduped while untrusted.
	if err := reg.SendDesiredModels(provider.ID, []protocol.DesiredModelEntry{{
		ModelName: "protected", DesiredBuild: Qwen38NAXModelID,
	}}); err != nil {
		t.Fatal(err)
	}
	framesMu.Lock()
	defer framesMu.Unlock()
	if len(frames) != 2 || len(frames[0]) == 0 || len(frames[1]) != 0 {
		t.Fatalf("wire order = %+v, want nonempty then final empty revoke", frames)
	}
}

func TestClearIneligiblePendingModelLoadsAfterCapabilityRevocation(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{
		ID: Qwen38NAXModelID,
		RequiredProviderCapabilities: []string{
			ProviderCapabilityAppleM5,
			ProviderCapabilityMLXNAX,
		},
	}})
	provider := reg.Register("revoked-provider", nil, capabilityTestRegister(
		Qwen38NAXModelID,
		"M5",
		[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
	))
	attestCapabilityTestProvider(
		t,
		reg,
		provider,
		"M5",
		[]string{ProviderCapabilityAppleM5, ProviderCapabilityMLXNAX},
		capabilityTestMetallibHash,
	)

	reserved := reg.reservePendingModelLoads([]modelLoadAction{{
		providerID: provider.ID,
		modelID:    Qwen38NAXModelID,
	}}, time.Now())
	if len(reserved) != 1 || !reg.HasPendingModelLoad(provider.ID, Qwen38NAXModelID) {
		t.Fatal("eligible protected load was not reserved")
	}
	if cleared := reg.ClearIneligiblePendingModelLoads(provider.ID); cleared != 0 {
		t.Fatalf("eligible pending load cleared: %d", cleared)
	}

	provider.mu.Lock()
	provider.RuntimeVerified = false
	provider.RuntimeManifestChecked = false
	provider.MetallibVerified = false
	provider.RuntimeCapabilities = nil
	provider.mu.Unlock()
	if cleared := reg.ClearIneligiblePendingModelLoads(provider.ID); cleared != 1 {
		t.Fatalf("cleared pending loads = %d, want 1", cleared)
	}
	if reg.HasPendingModelLoad(provider.ID, Qwen38NAXModelID) {
		t.Fatal("revoked protected load still consumes pending budget")
	}
}
