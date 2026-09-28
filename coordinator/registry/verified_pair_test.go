package registry

import (
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const pairTestModel = "verified-pair-fixture-model"

func pairTestRegistry(t *testing.T) (*Registry, [2]*Provider, VerifiedPairRequest) {
	t.Helper()
	r := New(testLogger())
	r.SetModelCatalog([]CatalogEntry{{ID: pairTestModel}})
	r.SetReleasePolicyGeneration(7, true, nil)
	members := [2]*Provider{pairTestMember(t, r, "pair-a", "serial-a"), pairTestMember(t, r, "pair-b", "serial-b")}
	request := VerifiedPairRequest{Model: pairTestModel, PlanSHA256: sha256.Sum256([]byte("fixture-plan")),
		ProposedRuntimeBindingSHA256: sha256.Sum256([]byte("UNAPPROVED-native-binding")), Lifetime: time.Minute}
	t.Cleanup(func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		for s := range r.verifiedPairs.states {
			r.releaseVerifiedPairLocked(s)
		}
	})
	return r, members, request
}

func pairTestMember(t *testing.T, r *Registry, id, serial string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, id, pairTestModel, 100)
	processKey := sha256.Sum256([]byte("fixture-process-" + id))
	x, y := elliptic.P256().ScalarBaseMult([]byte(serial))
	se := base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), x, y))
	p.mu.Lock()
	p.PublicKey = base64.StdEncoding.EncodeToString(processKey[:])
	p.Attested, p.MDAVerified, p.SEKeyBound = true, true, true
	p.CodeAttested, p.FreshCodeAttested, p.MetallibVerified = true, true, true
	p.mu.Unlock()
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: se,
		EncryptionPublicKey: p.PublicKey, SerialNumber: serial, SecureEnclaveAvailable: true})
	if !p.GrantApplicationEvidenceIfNotUntrusted(ApplicationEvidence{SEPublicKey: se, Serial: serial,
		ProcessPublicKey: p.PublicKey, BinaryHash: strings.Repeat("a", 64), MetallibHash: strings.Repeat("b", 64),
		Backend: p.Backend, Version: p.Version, PolicyGeneration: 7, VerifiedAt: time.Now()}) {
		t.Fatal("fixture current release evidence refused")
	}
	return p
}

func pairTestReserve(t *testing.T, r *Registry, members [2]*Provider, request VerifiedPairRequest) (*VerifiedPairHandle, VerifiedPairMembership) {
	t.Helper()
	h, m, err := r.ReserveVerifiedPair(members, request)
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	return h, m
}

func pairTestPrepare(t *testing.T, r *Registry, h *VerifiedPairHandle, members [2]*Provider, m VerifiedPairMembership) {
	t.Helper()
	for _, p := range members {
		p.mu.Lock()
		p.BackendCapacity.Slots = nil
		p.CurrentModel, p.WarmModels = "", nil
		p.mu.Unlock()
		if err := r.AcknowledgeVerifiedPairPrepared(h, p, m.TranscriptSHA256); err != nil {
			t.Fatalf("prepare: %v", err)
		}
	}
}

func pairTestActive(t *testing.T, r *Registry, members [2]*Provider, request VerifiedPairRequest) (*VerifiedPairHandle, VerifiedPairMembership) {
	t.Helper()
	h, m := pairTestReserve(t, r, members, request)
	pairTestPrepare(t, r, h, members, m)
	if _, err := r.CommitVerifiedPairOwners(h); err != nil {
		t.Fatalf("commit: %v", err)
	}
	return h, m
}

func pairTestDone(t *testing.T, h *VerifiedPairHandle) {
	t.Helper()
	select {
	case <-h.Done():
	default:
		t.Fatal("pair invalidation was not published")
	}
}

func TestVerifiedPairExcludesRealRoutingAndLoadReaders(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	if findRoutableProvider(r, pairTestModel) == nil {
		t.Fatal("ordinary solo baseline unavailable")
	}
	h, m := pairTestReserve(t, r, members, request)
	if m.Members[0].ProcessPublicKey != members[0].PublicKey || m.Members[1].DeviceSerial != "serial-b" ||
		m.TranscriptSHA256 != verifiedPairTranscript(m) || m.Suite != VerifiedPairSuite {
		t.Fatal("membership lost live identity binding")
	}
	if findRoutableProvider(r, pairTestModel) != nil {
		t.Fatal("solo routed a pair-held device")
	}
	if count, _, _ := r.QuickCapacityCheck(pairTestModel, 1, 1, RequestTraits{}); count != 0 {
		t.Fatal("pair advertised as solo capacity")
	}
	r.mu.RLock()
	members[0].mu.Lock()
	_, reason := r.warmPoolCandidateReasonLocked(members[0], pairTestModel, time.Now())
	warm := r.providerHasWarmModelLocked(members[0], pairTestModel, time.Now())
	members[0].mu.Unlock()
	_, loadable := r.modelLoadCandidatePendingLocked(members[1], pairTestModel, time.Now())
	r.mu.RUnlock()
	if reason != warmColdPairReserved || warm || loadable {
		t.Fatal("warming/load reader ignored pair hold")
	}
	for _, call := range []func() error{
		func() error { return r.SendLoadModel(members[0].ID, pairTestModel) },
		func() error { return r.SendPrefetchModel(members[1].ID, pairTestModel, 1) },
		func() error {
			return r.SendDesiredModels(members[0].ID, []protocol.DesiredModelEntry{{DesiredBuild: pairTestModel}})
		},
	} {
		if !errors.Is(call(), ErrVerifiedPairBusy) {
			t.Fatal("model command crossed pair hold")
		}
	}
	revoked := false
	r.desiredModelsSender = func(_ string, entries []protocol.DesiredModelEntry) error { revoked = len(entries) == 0; return nil }
	if err := r.SendDesiredModels(members[0].ID, nil); err != nil || !revoked {
		t.Fatal("pair blocked empty desired-model revocation")
	}
	if err := r.CancelVerifiedPair(h); err != nil {
		t.Fatal(err)
	}
	pairTestDone(t, h)
	if findRoutableProvider(r, pairTestModel) == nil {
		t.Fatal("pending cancel did not restore unchanged solo routing")
	}
}

func TestVerifiedPairRequiresBilateralPreparationAndExactRelease(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	h, m := pairTestReserve(t, r, members, request)
	if _, err := r.CommitVerifiedPairOwners(h); !errors.Is(err, ErrVerifiedPairPhase) {
		t.Fatal("unprepared commit")
	}
	if err := r.AcknowledgeVerifiedPairPrepared(h, members[0], m.TranscriptSHA256); !errors.Is(err, ErrVerifiedPairBusy) {
		t.Fatal("idle loaded slot mistaken for retired weights")
	}
	pairTestPrepare(t, r, h, members, m)
	if err := r.AcknowledgeVerifiedPairPrepared(h, members[0], m.TranscriptSHA256); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("duplicate preparation accepted")
	}
	if _, err := r.CommitVerifiedPairOwners(h); err != nil {
		t.Fatal(err)
	}
	if _, err := r.ValidateVerifiedPair(h); err != nil {
		t.Fatal(err)
	}
	wrong := m.TranscriptSHA256
	wrong[0] ^= 1
	if err := r.ObserveVerifiedPairOwnerReleased(h, members[0], wrong); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("unbound release accepted")
	}
	if err := r.ObserveVerifiedPairOwnerReleased(h, members[0], m.TranscriptSHA256); err != nil {
		t.Fatal(err)
	}
	pairTestDone(t, h)
	if _, _, err := r.ReserveVerifiedPair(members, request); !errors.Is(err, ErrVerifiedPairBusy) {
		t.Fatal("one release freed both devices")
	}
	if err := r.ObserveVerifiedPairOwnerReleased(h, members[0], m.TranscriptSHA256); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("duplicate release accepted")
	}
	if err := r.ObserveVerifiedPairOwnerReleased(h, members[1], m.TranscriptSHA256); err != nil {
		t.Fatal(err)
	}
	if _, _, err := r.ReserveVerifiedPair(members, request); err != nil {
		t.Fatalf("both bound releases did not release pair: %v", err)
	}
}

func TestVerifiedPairOldHandlesCannotReleaseReplacement(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	old, first := pairTestReserve(t, r, members, request)
	if err := r.CancelVerifiedPair(old); err != nil {
		t.Fatal(err)
	}
	current, second := pairTestReserve(t, r, members, request)
	if first.Epoch == second.Epoch || first.Generation >= second.Generation || first.TranscriptSHA256 == second.TranscriptSHA256 {
		t.Fatal("replacement reused generation or epoch")
	}
	if err := r.CancelVerifiedPair(old); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("old cancel touched replacement")
	}
	if err := r.AcknowledgeVerifiedPairPrepared(current, members[0], first.TranscriptSHA256); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("old transcript prepared replacement")
	}
	if err := r.ObserveVerifiedPairOwnerReleased(old, members[0], first.TranscriptSHA256); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("old owner release touched replacement")
	}
	other := New(testLogger())
	if err := other.CancelVerifiedPair(current); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("cross-registry handle accepted")
	}
	select {
	case <-current.Done():
		t.Fatal("replacement was invalidated")
	default:
	}
}
