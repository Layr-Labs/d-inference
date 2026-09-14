package api

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// dummyMDMClient returns a non-nil *mdm.Client (no network at construction) so
// tryTrustReuseFastSkip's "MDM configured" gate (FIX C) is satisfied in unit tests
// that don't stand up a fake MicroMDM server.
func dummyMDMClient() *mdm.Client {
	return mdm.NewClient("http://127.0.0.1:1", "test", quietLogger())
}

// Two distinct, valid 64-char SHA-256 hex digests for binary-hash gate tests.
var (
	trHashA = strings.Repeat("a", 64)
	trHashB = strings.Repeat("b", 64)
	trHashC = strings.Repeat("c", 64)
	trHashD = strings.Repeat("d", 64)
)

func trBoolPtr(b bool) *bool { return &b }

// hardwareReuseRecord builds a fresh, all-gates-good record for the given device.
func hardwareReuseRecord(seKey, serial, binaryHash string, at time.Time) store.ProviderTrustReuse {
	return store.ProviderTrustReuse{
		SEPubKey:                seKey,
		Serial:                  serial,
		TrustLevel:              string(registry.TrustHardware),
		LastVerifiedBinaryHash:  binaryHash,
		SIPEnabled:              true,
		SecureBootFull:          true,
		MDAUDID:                 "UDID-1",
		HardwareProofVerifiedAt: at,
		EvidenceGeneration:      1,
	}
}

func TestApprovedReleaseTransitionDerivedFromActiveRuntimePolicy(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	for _, release := range []store.Release{
		{Version: "0.8.14", Platform: "macos-arm64", Backend: "mlx-swift",
			BinaryHash: trHashA, MetallibHash: trHashC, Active: true},
		{Version: "0.8.15", Platform: "macos-arm64", Backend: "mlx-swift",
			BinaryHash: trHashB, MetallibHash: trHashC, Active: true},
		{Version: "0.8.16", Platform: "macos-arm64", Backend: "mlx-swift",
			BinaryHash: trHashD, MetallibHash: trHashC, Active: false},
	} {
		release := release
		if err := st.SetRelease(&release); err != nil {
			t.Fatalf("set release: %v", err)
		}
	}
	srv.SyncBinaryHashes()
	processKey := testPublicKeyB64()
	p := srv.registry.Register("release-proof", nil, &protocol.RegisterMessage{
		Backend: "mlx-swift", Version: "0.8.15",
		PublicKey: processKey, APNsDeviceToken: "token-current",
	})
	p.Mu().Lock()
	p.Version = "0.8.15"
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.MetallibVerified = true
	p.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "se", SerialNumber: "SER",
		BinaryHash: trHashB,
	}
	p.Mu().Unlock()
	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashB, SIPEnabled: trBoolPtr(true),
		SecureBootEnabled: trBoolPtr(true),
		TemplateHashes:    map[string]string{"mlx_metallib": trHashC},
	}
	fact, evidence, ok := srv.deriveApprovedReleaseTransition(p, resp, true)
	if !ok || !fact.Approved || fact.BinaryHash != trHashB ||
		fact.Version != "0.8.15" || fact.Platform != "macos-arm64" ||
		evidence.ProcessPublicKey != processKey {
		t.Fatalf("active release proof rejected: fact=%+v evidence=%+v ok=%v", fact, evidence, ok)
	}
	if _, allowedFromOld := fact.ApprovedFromBinaryHashes[trHashA]; !allowedFromOld {
		t.Fatal("active non-downgrade predecessor must be approved")
	}
	if _, allowedFromInactive := fact.ApprovedFromBinaryHashes[trHashD]; allowedFromInactive {
		t.Fatal("inactive release hash must not be approved")
	}

	p.Mu().Lock()
	p.Version = "0.8.14"
	p.AttestationResult.BinaryHash = trHashA
	p.Mu().Unlock()
	resp.BinaryHash = trHashA
	oldFact, _, oldOK := srv.deriveApprovedReleaseTransition(p, resp, true)
	if !oldOK {
		t.Fatal("active old release should still prove its own application")
	}
	if _, downgrade := oldFact.ApprovedFromBinaryHashes[trHashB]; downgrade {
		t.Fatal("new-to-old downgrade must not be an approved transition")
	}
	p.Mu().Lock()
	p.Version = "0.8.15"
	p.AttestationResult.BinaryHash = trHashB
	p.Mu().Unlock()
	resp.BinaryHash = trHashB

	resp.BinaryHash = trHashD
	p.Mu().Lock()
	p.AttestationResult.BinaryHash = trHashD
	p.Mu().Unlock()
	if _, _, ok := srv.deriveApprovedReleaseTransition(p, resp, true); ok {
		t.Fatal("inactive release must fail closed")
	}
	resp.BinaryHash = trHashB
	resp.TemplateHashes["mlx_metallib"] = trHashD
	p.Mu().Lock()
	p.AttestationResult.BinaryHash = trHashB
	p.Mu().Unlock()
	if _, _, ok := srv.deriveApprovedReleaseTransition(p, resp, true); ok {
		t.Fatal("metallib mismatch must fail closed")
	}
	if _, _, ok := srv.deriveApprovedReleaseTransition(p, resp, false); ok {
		t.Fatal("unsigned posture must fail closed")
	}
}

// TestApprovedReleaseTransitionMatchesEmptyBackendRelease is the review
// finding-4 regression: an ACTIVE release row persisted with an empty backend
// (the migration added the column with an empty default and registration
// accepts an omitted backend) must not leave providers permanently unroutable.
// An empty release backend matches the provider-reported backend, and the
// derived fact/evidence is stamped with the provider's backend so routing's
// evidence.Backend == provider.Backend check holds. An exact-backend row is
// preferred when both exist.
func TestApprovedReleaseTransitionMatchesEmptyBackendRelease(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	legacy := store.Release{Version: "0.8.15", Platform: "macos-arm64", Backend: "",
		BinaryHash: trHashA, MetallibHash: trHashC, Active: true}
	if err := st.SetRelease(&legacy); err != nil {
		t.Fatalf("set legacy release: %v", err)
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}
	processKey := testPublicKeyB64()
	p := srv.registry.Register("legacy-release-proof", nil, &protocol.RegisterMessage{
		Backend: "mlx-swift", Version: "0.8.15",
		PublicKey: processKey, APNsDeviceToken: "token-current",
	})
	p.Mu().Lock()
	p.Version = "0.8.15"
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.MetallibVerified = true
	p.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "se", SerialNumber: "SER",
		BinaryHash: trHashA,
	}
	p.Mu().Unlock()
	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashA, SIPEnabled: trBoolPtr(true),
		SecureBootEnabled: trBoolPtr(true),
		TemplateHashes:    map[string]string{"mlx_metallib": trHashC},
	}
	fact, evidence, ok := srv.deriveApprovedReleaseTransition(p, resp, true)
	if !ok || !fact.Approved {
		t.Fatalf("legacy empty-backend release rejected: fact=%+v ok=%v", fact, ok)
	}
	if fact.Backend != "mlx-swift" || evidence.Backend != "mlx-swift" {
		t.Fatalf("empty release backend must be stamped with the provider backend, got fact=%q evidence=%q",
			fact.Backend, evidence.Backend)
	}
	if _, fromSelf := fact.ApprovedFromBinaryHashes[trHashA]; !fromSelf {
		t.Fatal("empty-backend release must participate in approved-from set")
	}
	// The carried-forward predicate agrees: the evidence remains approved
	// across a policy rebuild of the same inventory.
	if !srv.releasePolicyOwner().Snapshot().ApprovesEvidence(evidence) {
		t.Fatal("evidence from an empty-backend release must survive a policy rebuild")
	}

	// A row with an explicit matching backend is preferred over the wildcard.
	exact := store.Release{Version: "0.8.15", Platform: "macos-arm64", Backend: "mlx-swift",
		BinaryHash: trHashA, MetallibHash: trHashC, Active: true}
	if err := st.SetRelease(&exact); err != nil {
		t.Fatalf("set exact release: %v", err)
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("re-sync: %v", err)
	}
	if _, evidence, ok := srv.deriveApprovedReleaseTransition(p, resp, true); !ok || evidence.Backend != "mlx-swift" {
		t.Fatalf("exact-backend release must still match: evidence=%+v ok=%v", evidence, ok)
	}
}

func TestApprovedTransitionGrantsWithoutMDMOrAPNs(t *testing.T) {
	srv, provider, clock := trustReuseFastSkipProvider(t)
	processKey, processPrivate, sePrivate, sePublic := providerKeyMaterial(t)
	provider.Mu().Lock()
	provider.PublicKey = processKey
	provider.AttestationResult.PublicKey = sePublic
	provider.APNsDeviceToken = "token-current"
	provider.Version = "0.8.15"
	provider.ApplicationEvidence = registry.ApplicationEvidence{
		SEPublicKey: sePublic, Serial: "SERIAL-1",
		ProcessPublicKey: processKey, APNsToken: "token-current",
		BinaryHash: trHashB,
		Version:    "0.8.15", Platform: "macos-arm64", Backend: "mlx-swift",
		VerifiedAt:         (*clock)(),
		EvidenceGeneration: 1,
		PolicyGeneration:   1,
	}
	provider.Mu().Unlock()
	seedReleasePolicyForTest(t, srv, releasePolicyObservation{
		Generation: 1, Required: true,
		// Release A (trHashA, 0.8.14) stays ACTIVE: the cached APNs proof
		// earned under it may authorize the B transition resume below.
		ByBinaryHash: map[string][]approvedReleasePolicy{
			trHashA: {{Version: "0.8.14", Platform: "macos-arm64", Backend: "mlx-swift"}},
		},
	})
	seedTrustReuseRecord(t, srv,
		hardwareReuseRecord(sePublic, "SERIAL-1", trHashA, (*clock)()))
	resp := goodFastSkipResp()
	resp.BinaryHash = trHashB
	fact := approvedReleaseTransitionFact{
		Approved: true, BinaryHash: trHashB, Version: "0.8.15",
		Platform: "macos-arm64", Backend: "mlx-swift", PolicyGeneration: 1,
		ApprovedFromBinaryHashes: map[string]struct{}{trHashA: {}},
	}
	if !srv.tryTrustReuseFastSkip("prov-fs", provider, resp, true, fact) {
		t.Fatal("approved transition should grant from fresh device evidence")
	}

	pushes := 0
	srvControls := configureCodeIdentityFixture(srv, codeidentity.DefaultConfig())
	srv.SetCodeAttestor(&fakeCodeAttestor{
		onSend: func(_, _, _, _ string) error {
			pushes++
			return nil
		},
	})
	srvControls.resumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		return completeResumeRoundTrip(
			t, srv, provider, "prov-fs",
			processPrivate, sePrivate, message,
		)
	}
	// The no-new-push path is authorized only by this prior genuine APNs proof,
	// then completed by a live encrypted process-key possession challenge.
	seedFreshProcessAttestation(t, srv,
		sePublic, "0.8.14", "token-current", processKey, trHashA)
	provider.SignalApplicationProofSettled()
	srv.codeAttestLoop(context.Background(), "prov-fs", provider)
	if pushes != 0 || !provider.GetCodeAttested() ||
		!provider.GetFreshCodeAttested() {
		t.Fatalf("combined reusable APNs proof: pushes=%d code=%v fresh=%v",
			pushes, provider.GetCodeAttested(), provider.GetFreshCodeAttested())
	}
}

func TestSelfReportedActiveHashAloneCannotGrantCodeIdentity(t *testing.T) {
	srv, provider, clock := trustReuseFastSkipProvider(t)
	provider.Mu().Lock()
	provider.APNsDeviceToken = "token-current"
	provider.Version = "0.8.15"
	provider.RuntimeVerified = true
	provider.RuntimeManifestChecked = true
	provider.MetallibVerified = true
	provider.Mu().Unlock()
	// The grant now validates its policy generation against the registry's
	// live generation atomically; publish generation 1 first.
	srv.registry.SetReleasePolicyGeneration(1, true, nil)
	evidence := registry.ApplicationEvidence{
		SEPublicKey: "se-pub-key-bytes", Serial: "SERIAL-1",
		ProcessPublicKey: provider.PublicKey, APNsToken: "token-current",
		BinaryHash: trHashB, Version: "0.8.15", Platform: "macos-arm64",
		Backend: "mlx-swift", VerifiedAt: (*clock)(), PolicyGeneration: 1,
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("precondition: fresh application fact was rejected")
	}
	seedReleasePolicyForTest(t, srv, releasePolicyObservation{
		Generation: 1, Required: true,
		ByBinaryHash: map[string][]approvedReleasePolicy{},
	})
	if srv.tryCrossVersionReuse(context.Background(), "prov-fs", provider) ||
		provider.GetCodeAttested() || provider.GetFreshCodeAttested() {
		t.Fatal("self-reported active hash bypassed genuine APNs proof")
	}
}

func trustReuseServer(t *testing.T) (*Server, store.Store) {
	t.Helper()
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	return srv, st
}

// newTrustReuseProvider registers a fresh, online (not-untrusted, epoch 0) provider
// with the given SE key + serial, for exercising recordTrustReuse's epoch-checked
// write-through (FIX A) and the late-SecurityInfo path (FIX B).
func newTrustReuseProvider(t *testing.T, srv *Server, id, seKey, serial string) *registry.Provider {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", PublicKey: testPublicKeyB64(),
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	}
	p := srv.registry.Register(id, nil, msg)
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: serial, PublicKey: seKey}
	p.Mu().Unlock()
	return p
}

// trustReuseFastSkipProvider builds a server + self_signed provider with a valid
// registration-bound attestation (serial + SE key + binary hash), and a fake clock
// on the cache so freshness is deterministic.
func trustReuseFastSkipProvider(t *testing.T) (*Server, *registry.Provider, *func() time.Time) {
	t.Helper()
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.mdmClient = dummyMDMClient() // satisfy the FIX C "MDM configured" gate
	cur := time.Now()
	clock := func() time.Time { return cur }
	setTrustReuseClock(t, srv, clock)

	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", PublicKey: testPublicKeyB64(),
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	}
	p := srv.registry.Register("prov-fs", nil, msg)
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.AttestationResult = &attestation.VerificationResult{
		Valid: true, SerialNumber: "SERIAL-1", SIPEnabled: true, SecureBootEnabled: true,
		PublicKey: "se-pub-key-bytes", BinaryHash: trHashA,
	}
	p.Mu().Unlock()
	return srv, p, &clock
}

// goodFastSkipResp is a fresh SIGNED challenge response that satisfies the
// posture + binary gates for the device built by trustReuseFastSkipProvider.
func goodFastSkipResp() *protocol.AttestationResponseMessage {
	return &protocol.AttestationResponseMessage{
		SIPEnabled:        trBoolPtr(true),
		SecureBootEnabled: trBoolPtr(true),
		BinaryHash:        trHashA,
	}
}

// TestApplyLateSecurityInfoCachesReuse proves FIX B: a self_signed→hardware upgrade
// via a late SecurityInfo persists a trust-reuse record (same epoch-checked
// write-through as the synchronous MDM path) so it gets restart-survivable
// fast-skip.
func TestApplyLateSecurityInfoCachesReuse(t *testing.T) {
	fake := &fakeMDMServer{device: &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true}}
	srv, p := mdmReliabilityServer(t, fake)
	srv.SeedTrustReuseCache(context.Background()) // wire store + hook
	// Give the provider a usable signed binary hash so the reuse record can bind.
	p.Mu().Lock()
	p.AttestationResult.BinaryHash = trHashA
	p.Mu().Unlock()
	bindLateSecurityInfoForTest(t, srv, p, "UDID-1")

	srv.ApplyLateSecurityInfo(
		"UDID-1", lateSecurityInfoCommandUUID,
		&mdm.SecurityInfoResponse{
			SystemIntegrityProtectionEnabled: true,
			SecureBootLevel:                  "full",
		},
	)

	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("late SecurityInfo must upgrade to hardware, got %q", lvl)
	}
	if !hasReusableTrust(srv, "se-pub-key-bytes", "SERIAL-1", trHashA) {
		t.Fatal("late SecurityInfo grant must cache a reusable trust-reuse record (FIX B)")
	}
	if rows, _ := srv.store.ListProviderTrustReuse(context.Background()); len(rows) != 1 {
		t.Fatalf("late grant must persist exactly one reuse row, got %d", len(rows))
	}
}

// TestTrustReuseFastSkipRequiresMDMConfigured proves FIX C: with a valid fresh
// record and all other gates passing, a nil mdmClient (no-MDM / misconfigured
// deploy) makes the fast-skip decline so hardware is never granted from cache with
// no live MDM fallback.
func TestTrustReuseFastSkipRequiresMDMConfigured(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	srv.mdmClient = nil // no MDM configured
	seedTrustReuseRecord(t, srv, hardwareReuseRecord("se-pub-key-bytes", "SERIAL-1", trHashA, time.Now()))

	if srv.tryTrustReuseFastSkip("prov-fs", p, goodFastSkipResp(), true) {
		t.Fatal("fast-skip must NOT grant when no MDM client is configured (no live fallback)")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
		t.Fatalf("provider must stay self_signed, got %q", lvl)
	}
}

// TestApplyLateSecurityInfoGrantsWithoutBinaryHashPersistsNothing (review
// finding 2, late MDM path): a late SecurityInfo callback for a provider that
// never self-reported a binary hash still upgrades the live connection to
// hardware — the device proof is complete — while persisting/caching no
// unbindable reuse record.
func TestApplyLateSecurityInfoGrantsWithoutBinaryHashPersistsNothing(t *testing.T) {
	fake := &fakeMDMServer{device: &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true}}
	srv, p := mdmReliabilityServer(t, fake)
	srv.SeedTrustReuseCache(context.Background())
	// mdmReliabilityServer leaves AttestationResult.BinaryHash empty.
	bindLateSecurityInfoForTest(t, srv, p, "UDID-1")

	srv.ApplyLateSecurityInfo(
		"UDID-1", lateSecurityInfoCommandUUID,
		&mdm.SecurityInfoResponse{
			SystemIntegrityProtectionEnabled: true,
			SecureBootLevel:                  "full",
		},
	)

	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("late SecurityInfo without optional binary hash must still grant hardware, got %q", lvl)
	}
	if rows, _ := srv.store.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("no reuse record may be cached without a binary hash, got %d rows", len(rows))
	}
	if srv.trustReuse.HasFreshRecord("se-pub-key-bytes", "SERIAL-1") {
		t.Fatal("hashless late grant must not cache an unbindable reuse record")
	}
}

// TestApplyLateSecurityInfoHashlessEvidencePersistsForRestart covers the
// scheduler callback sibling of synchronous MDM verification. A production-
// shape hashless registration with current SE/process-bound application
// evidence must persist the approved hash and reseed reusable device evidence.
func TestApplyLateSecurityInfoHashlessEvidencePersistsForRestart(t *testing.T) {
	fake := &fakeMDMServer{device: &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true}}
	srv, p := mdmReliabilityServer(t, fake)
	srv.SeedTrustReuseCache(context.Background())
	p.Mu().Lock()
	p.ApplicationEvidence = registry.ApplicationEvidence{
		SEPublicKey:        "se-pub-key-bytes",
		ProcessPublicKey:   p.PublicKey,
		BinaryHash:         trHashA,
		EvidenceGeneration: 1,
	}
	p.Mu().Unlock()
	bindLateSecurityInfoForTest(t, srv, p, "UDID-1")

	srv.ApplyLateSecurityInfo(
		"UDID-1", lateSecurityInfoCommandUUID,
		&mdm.SecurityInfoResponse{
			SystemIntegrityProtectionEnabled: true,
			SecureBootLevel:                  "full",
		},
	)

	rows, err := srv.store.ListProviderTrustReuse(context.Background())
	if err != nil || len(rows) != 1 || rows[0].LastVerifiedBinaryHash != trHashA {
		t.Fatalf("late hashless grant rows=%+v err=%v, want one row bound to %q", rows, err, trHashA)
	}
	if !hasReusableTrust(srv, "se-pub-key-bytes", "SERIAL-1", trHashA) {
		t.Fatal("late hashless grant did not install reusable device evidence")
	}

	restarted := NewServer(registry.New(quietLogger()), srv.store, ServerConfig{}, quietLogger())
	if err := restarted.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("restart seed: %v", err)
	}
	if !hasReusableTrust(restarted, "se-pub-key-bytes", "SERIAL-1", trHashA) {
		t.Fatal("late hashless device evidence did not survive restart reseeding")
	}
}

// fastSkipChallengeResp builds a fully-signed challenge response (challenge sig +
// status sig so statusFieldsTrusted=true) that satisfies the fast-skip posture +
// binary gates for a provider registered with createTestAttestationJSONWithBinaryHash.
func fastSkipChallengeResp(t *testing.T, nonce, ts, pubKey, binHash string) *protocol.AttestationResponseMessage {
	t.Helper()
	sip, sb, rdma := true, true, true
	resp := &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             nonce,
		Signature:         testChallengeSignature(nonce, ts, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sip,
		SecureBootEnabled: &sb,
		RDMADisabled:      &rdma,
		BinaryHash:        binHash,
	}
	resp.StatusSignature = testStatusSignature(t, attestation.StatusCanonicalInput{
		Nonce: nonce, Timestamp: ts, RDMADisabled: &rdma,
		SIPEnabled: &sip, SecureBootEnabled: &sb, BinaryHash: binHash,
	}, pubKey)
	return resp
}

// TestVerifyChallengeFastSkipGrantDrainsQueue proves FIX 3: when the fast-skip
// grants hardware from the trust-reuse cache, verifyChallengeResponse drains the
// provider's queued work immediately (instead of waiting for a heartbeat / 120s
// timeout). Without the drain the queued request would not dispatch from the
// challenge path at all.
func TestVerifyChallengeFastSkipGrantDrainsQueue(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.mdmClient = dummyMDMClient()
	srv.SeedTrustReuseCache(context.Background())

	const model = "fast-skip-drain-model"
	binHash := trHashA
	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		DecodeTPS:               90,
		PrefillTPS:              900,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, binHash),
	}
	p := reg.Register("prov-drain", nil, regMsg)
	srv.verifyProviderAttestation(context.Background(), "prov-drain", p, regMsg)

	// Test attestation blobs carry no serial; set one + make the provider routable.
	p.Mu().Lock()
	seKey := p.AttestationResult.PublicKey
	p.AttestationResult.SerialNumber = "SER-DRAIN"
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "running"}},
	}
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.Mu().Unlock()

	// Seed a fresh trust-reuse record so the fast-skip can grant.
	seedTrustReuseRecord(t, srv, hardwareReuseRecord(seKey, "SER-DRAIN", binHash, time.Now()))

	// Enqueue work for the model.
	req := &registry.QueuedRequest{
		RequestID:  "queued-fast-skip",
		Model:      model,
		ResponseCh: make(chan *registry.Provider, 1),
		Pending: &registry.PendingRequest{
			RequestID: "queued-fast-skip", Model: model,
			RequestedMaxTokens: 256, EstimatedPromptTokens: 50,
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	nonce, ts := "nonce-fs", "2026-04-24T12:00:00Z"
	srv.verifyChallengeResponse("prov-drain", p, &pendingChallenge{nonce: nonce, timestamp: ts},
		fastSkipChallengeResp(t, nonce, ts, pubKey, binHash))

	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("fast-skip must grant hardware, got %q", lvl)
	}
	select {
	case assigned := <-req.ResponseCh:
		if assigned == nil || assigned.ID != "prov-drain" {
			t.Fatalf("expected drain dispatch to prov-drain, got %+v", assigned)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fast-skip grant must drain the queued request to the provider (FIX 3)")
	}
}

// coveredReuseRecord is hardwareReuseRecord plus a coordinator-measured
// continuity watermark.
func coveredReuseRecord(seKey, serial, binaryHash string, provedAt, coveredAt time.Time) store.ProviderTrustReuse {
	rec := hardwareReuseRecord(seKey, serial, binaryHash, provedAt)
	rec.ContinuousCoverageUntil = &coveredAt
	return rec
}
