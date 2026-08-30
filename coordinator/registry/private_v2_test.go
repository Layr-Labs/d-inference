package registry

import (
	"errors"
	"sync"
	"testing"
)

func markPrivateV2Capable(provider *Provider) {
	provider.mu.Lock()
	defer provider.mu.Unlock()
	provider.PrivacyCapabilities.PrivateV2 = true
	provider.MDAVerified = true
	provider.SEKeyBound = true
	provider.MDACertChain = [][]byte{{1, 2, 3}}
	certificate := provider.ApplicationEvidence.CertifiedProcessEvidence
	certificate.ProcessEvidenceCanonical = []byte(`{"version":"process_evidence_v1"}`)
	certificate.ProcessEvidenceSignature = "AQ=="
	provider.ApplicationEvidence.CertifiedProcessEvidence = certificate
	provider.UpdateDesiredGeneration = 8
	provider.desiredModelGeneration = 9
}

func privateV2RegistryFixture(t *testing.T, id, model, hash string) (*Registry, *Provider) {
	t.Helper()
	reg := New(testLogger())
	reg.SetReleasePolicyGeneration(7, true)
	reg.SetModelCatalog([]CatalogEntry{{ID: model, WeightHash: hash}})
	message := capabilityTestRegister(model, "M4", nil)
	message.Models[0].WeightHash = hash
	provider := reg.Register(id, nil, message)
	testMakeTextRoutable(provider)
	attestCapabilityTestProvider(t, reg, provider, "M4", nil, capabilityTestMetallibHash)
	markPrivateV2Capable(provider)
	return reg, provider
}

func TestPrivateV2ExactReservationBindsEveryGeneration(t *testing.T) {
	const model = "private-v2-generation-model"
	reg, provider := privateV2RegistryFixture(t, "private-provider", model, "manifest-hash")
	probe := &PendingRequest{RequestID: "preflight", Model: model, RequestedMaxTokens: 64}
	selected, snapshot, _ := reg.SelectPrivateV2Provider(model, probe)
	if selected != provider {
		t.Fatalf("selected = %v, want exact provider", selected)
	}
	if snapshot.ReleaseGeneration != 8 || snapshot.ModelGeneration != 9 ||
		snapshot.Certificate.PolicyGeneration != 7 || snapshot.ModelManifestHash != "manifest-hash" {
		t.Fatalf("unexpected private snapshot: %+v", snapshot)
	}

	assertChanged := func(name string, mutate func(), restore func()) {
		t.Helper()
		mutate()
		request := &PendingRequest{RequestID: "submit-" + name, Model: model, RequestedMaxTokens: 64}
		if got, err := reg.ReservePrivateV2Provider(provider.ID, model, request, snapshot); got != nil || err == nil {
			t.Fatalf("%s change reserved provider=%v err=%v", name, got, err)
		}
		restore()
	}
	assertChanged("release", func() {
		provider.mu.Lock()
		provider.UpdateDesiredGeneration++
		provider.mu.Unlock()
	}, func() {
		provider.mu.Lock()
		provider.UpdateDesiredGeneration--
		provider.mu.Unlock()
	})
	assertChanged("model", func() {
		provider.mu.Lock()
		provider.desiredModelGeneration++
		provider.mu.Unlock()
	}, func() {
		provider.mu.Lock()
		provider.desiredModelGeneration--
		provider.mu.Unlock()
	})
	assertChanged("evidence", func() {
		provider.mu.Lock()
		provider.modelEvidenceGeneration++
		provider.mu.Unlock()
	}, func() {
		provider.mu.Lock()
		provider.modelEvidenceGeneration--
		provider.mu.Unlock()
	})
	assertChanged("certificate", func() {
		provider.mu.Lock()
		provider.ApplicationEvidence.CertifiedProcessEvidence.ChallengeGeneration = "changed"
		provider.mu.Unlock()
	}, func() {
		provider.mu.Lock()
		provider.ApplicationEvidence.CertifiedProcessEvidence.ChallengeGeneration = snapshot.ChallengeGeneration
		provider.mu.Unlock()
	})

	request := &PendingRequest{RequestID: "submit-ok", Model: model, RequestedMaxTokens: 64}
	reserved, err := reg.ReservePrivateV2Provider(provider.ID, model, request, snapshot)
	if err != nil || reserved != provider {
		t.Fatalf("unchanged exact reservation = %v, %v", reserved, err)
	}
	provider.RemovePending(request.RequestID)
}

func TestPrivateV2ExactProviderUnavailableNeverFallsBack(t *testing.T) {
	const model = "private-v2-no-fallback-model"
	reg, leased := privateV2RegistryFixture(t, "leased", model, "manifest-hash")
	otherMessage := capabilityTestRegister(model, "M4", nil)
	otherMessage.Models[0].WeightHash = "manifest-hash"
	other := reg.Register("other", nil, otherMessage)
	testMakeTextRoutable(other)
	attestCapabilityTestProvider(t, reg, other, "M4", nil, capabilityTestMetallibHash)
	markPrivateV2Capable(other)

	_, snapshot, _ := reg.SelectPrivateV2Provider(model, &PendingRequest{RequestID: "preflight", Model: model, RequestedMaxTokens: 64})
	leasedID := snapshot.ProviderID
	reg.Disconnect(leasedID)
	request := &PendingRequest{RequestID: "submit", Model: model, RequestedMaxTokens: 64}
	got, err := reg.ReservePrivateV2Provider(leasedID, model, request, snapshot)
	if got != nil || !errors.Is(err, ErrPrivateV2ProviderUnavailable) {
		t.Fatalf("exact reservation after disconnect = %v, %v", got, err)
	}
	if other.GetPending(request.RequestID) != nil || leased.GetPending(request.RequestID) != nil {
		t.Fatal("failed exact reservation fell back or retained pending state")
	}
}

func TestPrivateV2CapabilityIsMandatory(t *testing.T) {
	const model = "private-v2-capability-model"
	reg, provider := privateV2RegistryFixture(t, "provider", model, "manifest-hash")
	provider.mu.Lock()
	provider.PrivacyCapabilities.PrivateV2 = false
	provider.mu.Unlock()
	selected, _, _ := reg.SelectPrivateV2Provider(model, &PendingRequest{RequestID: "preflight", Model: model, RequestedMaxTokens: 64})
	if selected != nil {
		t.Fatal("provider without explicit private_v2 capability was selected")
	}
}

func TestPrivateV2SelectionSkipsIncapableWinnerForCapableProvider(t *testing.T) {
	const model = "private-v2-capable-fallback-model"
	reg, incapable := privateV2RegistryFixture(t, "incapable", model, "manifest-hash")
	incapable.mu.Lock()
	incapable.PrivacyCapabilities.PrivateV2 = false
	incapable.DecodeTPS = 1_000
	incapable.mu.Unlock()

	message := capabilityTestRegister(model, "M4", nil)
	message.Models[0].WeightHash = "manifest-hash"
	capable := reg.Register("capable", nil, message)
	testMakeTextRoutable(capable)
	attestCapabilityTestProvider(t, reg, capable, "M4", nil, capabilityTestMetallibHash)
	markPrivateV2Capable(capable)
	capable.mu.Lock()
	capable.DecodeTPS = 10
	capable.mu.Unlock()

	selected, _, _ := reg.SelectPrivateV2Provider(model, &PendingRequest{
		RequestID: "preflight", Model: model, RequestedMaxTokens: 64,
	})
	if selected != capable {
		t.Fatalf("selected = %v, want capable private-v2 provider", selected)
	}
}

func TestPrivateV2CapabilityRequiresCertifiedFeatureFloor(t *testing.T) {
	const model = "private-v2-version-floor-model"
	reg, provider := privateV2RegistryFixture(t, "provider", model, "manifest-hash")
	provider.mu.Lock()
	provider.Version = "0.8.15"
	provider.ApplicationEvidence.Version = "0.8.15"
	provider.ApplicationEvidence.CertifiedProcessEvidence.ProviderVersion = "0.8.15"
	provider.mu.Unlock()
	selected, _, _ := reg.SelectPrivateV2Provider(model, &PendingRequest{
		RequestID: "preflight", Model: model, RequestedMaxTokens: 64,
	})
	if selected != nil {
		t.Fatal("provider below the certified private-v2 feature floor was selected")
	}
}

func TestPrivateV2InvalidationHookFiresOnDisconnectAndUntrust(t *testing.T) {
	const model = "private-v2-invalidation-model"
	reg, first := privateV2RegistryFixture(t, "disconnect-provider", model, "manifest-hash")
	var invalidated []string
	var invalidatedMu sync.Mutex
	reg.SetProviderInvalidatedHook(func(providerID string) {
		invalidatedMu.Lock()
		invalidated = append(invalidated, providerID)
		invalidatedMu.Unlock()
	})
	reg.Disconnect(first.ID)

	message := capabilityTestRegister(model, "M4", nil)
	message.Models[0].WeightHash = "manifest-hash"
	second := reg.Register("untrusted-provider", nil, message)
	reg.MarkUntrusted(second.ID)

	invalidatedMu.Lock()
	defer invalidatedMu.Unlock()
	if len(invalidated) != 2 || invalidated[0] != first.ID || invalidated[1] != second.ID {
		t.Fatalf("invalidation hook calls = %v", invalidated)
	}
}
