package provider_test

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func (f *consentSocketFixture) registerRewardInventory(t *testing.T) (*registry.Provider, *protocol.ModelAutopilotState) {
	t.Helper()
	state := savedConsent(true)
	state.Enabled = true
	state.SelectedModels = []string{"first-model", "second-model"}
	f.write(t, protocol.RegisterMessage{
		Type: protocol.TypeRegister, AuthToken: consentCaptureToken, PublicKey: testkit.PublicKeyB64(),
		Backend: registry.BackendMLXSwift, EncryptedResponseChunks: true,
		Hardware: protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true, TextProxyDisabled: true,
			AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true,
		},
		Models: []protocol.ModelInfo{
			{ID: "first-model", WeightHash: strings.Repeat("a", 64)},
			{ID: "second-model", WeightHash: strings.Repeat("b", 64)},
		},
		ModelAutopilot: state,
	})
	f.sync(t)
	ids := f.owner.registry.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("provider registration failed: %v", ids)
	}
	p := f.owner.registry.GetProvider(ids[0])
	p.CompleteProviderStateRestore()
	p.Mu().Lock()
	p.RuntimeVerified, p.RuntimeManifestChecked = true, true
	p.Mu().Unlock()
	f.owner.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: "first-model", WeightHash: strings.Repeat("a", 64)},
		{ID: "second-model", WeightHash: strings.Repeat("b", 64)},
	})
	return p, state
}

func (f *consentSocketFixture) authorizeRewardOS(t *testing.T, p *registry.Provider, osVersion string) {
	t.Helper()
	r := f.owner.registry
	r.SetAppAttestServingPolicy(true, 7)
	if !r.BindVerifiedMachineIdentity(p, consentCaptureAccount, "qualified-machine") {
		t.Fatal("bind authenticated registry identity")
	}
	now := time.Now()
	if !r.GrantAppAttestServingAuthorization(p, registry.AppAttestServingAuthorization{
		AccountID: consentCaptureAccount, MachineID: "qualified-machine", CredentialID: "qualified-credential",
		ConnectionID: p.ID, ProofSessionID: "proof", Endpoint: p.PublicKey, PolicyGeneration: 7,
		IssuedAt: now, ValidUntil: now.Add(time.Minute), MachineModel: p.Hardware.MachineModel,
		MemoryGB: p.Hardware.MemoryGB, OSVersion: osVersion,
	}) {
		t.Fatal("grant current authenticated OS")
	}
}

func TestAutopilotConsentCaptureQualificationTransitionsPreserveSavedConsentAndFIFO(t *testing.T) {
	f := newConsentSocket(t, nil)
	f.store.failBeforeConsent(func(context.Context, earningsfloor.Consent) error { return io.ErrUnexpectedEOF })
	p, state := f.registerRewardInventory(t)
	first := f.store.snapshot()[0].consent
	if !first.OptedIn || !first.Supported || first.Qualified {
		t.Fatalf("untrusted registration qualified or lost saved consent: %+v", first)
	}
	f.authorizeRewardOS(t, p, "27.0")
	f.heartbeat(t, state, 1)
	state.SelectedModels = state.SelectedModels[:1]
	f.heartbeat(t, state, 2)
	if calls := f.store.snapshot(); len(calls) != 3 {
		t.Fatalf("failed head did not bound store attempts: %+v", calls)
	}
	f.bind(t, first, consentCaptureAccount)
	f.store.failBeforeConsent(nil)
	f.write(t, map[string]any{"type": protocol.TypeAttestationResponse})
	f.sync(t)
	calls := f.store.snapshot()
	if len(calls) != 6 {
		t.Fatalf("qualification changes compacted as duplicate saved consent: %+v", calls)
	}
	for i, want := range []bool{false, true, false} {
		call := calls[i+3]
		if call.err != nil || !call.consent.OptedIn || !call.consent.Supported || call.consent.Qualified != want {
			t.Fatalf("qualification transition %d changed or failed: %+v", i, call)
		}
		if i > 0 && !call.consent.At.After(calls[i+2].consent.At) {
			t.Fatalf("qualification transitions lost server receive order: %+v", calls)
		}
	}
	rows := f.enrollments(t)
	if len(rows) != 1 || !rows[0].OptedIn || !rows[0].FirstObservedAt.Equal(first.At.Truncate(time.Microsecond)) {
		t.Fatalf("temporary ineligibility reset first opt-in: %+v", rows)
	}
}

func TestAutopilotConsentCaptureRechecksCurrentQualificationOnEachAcceptedHeartbeat(t *testing.T) {
	f := newConsentSocket(t, nil)
	p, state := f.registerRewardInventory(t)
	first := f.store.snapshot()[0].consent
	f.bind(t, first, consentCaptureAccount)
	f.authorizeRewardOS(t, p, "27")
	f.heartbeat(t, state, 1)
	calls := f.store.snapshot()
	if last := calls[len(calls)-1]; last.err != nil || !last.consent.Qualified {
		t.Fatalf("two eligible downloaded models did not qualify: %+v", calls)
	}
	f.authorizeRewardOS(t, p, "26.9")
	f.heartbeat(t, state, 2)
	calls = f.store.snapshot()
	if last := calls[len(calls)-1]; last.err != nil || !last.consent.OptedIn || last.consent.Qualified {
		t.Fatalf("older authenticated OS qualified or cleared saved consent: %+v", last)
	}
	f.authorizeRewardOS(t, p, "27")
	f.heartbeat(t, state, 3)
	f.owner.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "first-model", WeightHash: strings.Repeat("a", 64)}})
	f.heartbeat(t, state, 4)
	calls = f.store.snapshot()
	if last := calls[len(calls)-1]; last.err != nil || !last.consent.OptedIn || last.consent.Qualified {
		t.Fatalf("catalog deletion retained qualification or erased saved consent: %+v", last)
	}
	count := len(calls)
	f.heartbeat(t, state, 3)
	if got := len(f.store.snapshot()); got != count {
		t.Fatal("rejected capacity heartbeat journaled qualification")
	}
}

func TestAutopilotConsentCapturePreservesOriginalHardwareBeforeInventoryBinding(t *testing.T) {
	f := newConsentSocket(t, nil)
	f.store.failBeforeConsent(func(context.Context, earningsfloor.Consent) error { return io.ErrUnexpectedEOF })
	p, state := f.registerRewardInventory(t)
	first := f.store.snapshot()[0].consent
	if first.Chip != "Apple M3 Max" || first.MemoryGB != 64 || !first.OptedIn || first.Qualified {
		t.Fatalf("first registration did not capture bounded hardware before verification: %+v", first)
	}
	// A later accepted hardware projection cannot rewrite the original receipt.
	// Even while qualification stays false, its new cohort data is a transition.
	p.Mu().Lock()
	p.Hardware.ChipName, p.Hardware.MemoryGB = "Apple M4 Max", 128
	p.Mu().Unlock()
	f.heartbeat(t, state, 1)
	f.authorizeRewardOS(t, p, "27")
	f.heartbeat(t, state, 2)
	if calls := f.store.snapshot(); len(calls) != 3 {
		t.Fatalf("failed head should bound attempts before identity binding: %+v", calls)
	}
	f.bind(t, first, consentCaptureAccount)
	f.store.failBeforeConsent(nil)
	f.write(t, map[string]any{"type": protocol.TypeAttestationResponse})
	f.sync(t)
	calls := f.store.snapshot()
	if len(calls) != 6 || calls[3].consent != first {
		t.Fatalf("retry changed the original cohort snapshot or compacted hardware transition: %+v", calls)
	}
	for i, qualified := range []bool{false, true} {
		call := calls[i+4]
		if call.err != nil || call.consent.Chip != "Apple M4 Max" || call.consent.MemoryGB != 128 || call.consent.Qualified != qualified || !call.consent.At.After(calls[i+3].consent.At) {
			t.Fatalf("later hardware/qualification transition lost: %+v", calls)
		}
	}
	if rows := f.enrollments(t); len(rows) != 1 || !rows[0].FirstObservedAt.Equal(first.At.Truncate(time.Microsecond)) {
		t.Fatalf("later identity binding reanchored first consent: %+v", rows)
	}
}
