package registry

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type blockingProviderUpsertStore struct {
	store.Store
	calls   atomic.Int32
	started chan struct{}
	second  chan struct{}
	release chan struct{}
}

func (s *blockingProviderUpsertStore) UpsertProvider(
	ctx context.Context,
	record store.ProviderRecord,
) error {
	switch s.calls.Add(1) {
	case 1:
		close(s.started)
		select {
		case <-s.release:
		case <-ctx.Done():
			return ctx.Err()
		}
	case 2:
		close(s.second)
	}
	return s.Store.UpsertProvider(ctx, record)
}

func TestHardwareAdmissionGateCannotBeRelaxedBySelfRoute(t *testing.T) {
	reg := New(testLogger())
	reg.SetHardwareAdmissionEnforced(true)
	msg := testRegisterMessage()
	provider := reg.Register("pending-hardware", nil, msg)
	provider.mu.Lock()
	provider.RuntimeVerified = true
	provider.LastChallengeVerified = time.Now()
	provider.ChallengeVerifiedSIP = true
	provider.mu.Unlock()

	provider.mu.Lock()
	if reg.providerLivenessGateLocked(provider, TrustNone, true, time.Now()) {
		provider.mu.Unlock()
		t.Fatal("owner self-route bypassed hardware admission")
	}
	provider.mu.Unlock()

	if !reg.SetProviderHardwareAdmitted(provider, true) {
		t.Fatal("failed to mark provider admitted")
	}
	provider.mu.Lock()
	if !reg.providerLivenessGateLocked(provider, TrustNone, true, time.Now()) {
		provider.mu.Unlock()
		t.Fatal("admitted owner provider failed liveness gate")
	}
	provider.mu.Unlock()
}

func TestDisabledHardwareAdmissionPreservesRegistrationDefault(t *testing.T) {
	reg := New(testLogger())
	provider := reg.Register("legacy-default", nil, testRegisterMessage())
	if !provider.HardwareAdmissionStatus() {
		t.Fatal("disabled hardware policy changed legacy registration behavior")
	}
}

func TestPendingRegistrationStartsUnadmittedEvenBeforeEnforcement(t *testing.T) {
	reg := New(testLogger())
	provider := reg.RegisterPendingHardwareAdmission(
		"pending-before-policy-flip", nil, testRegisterMessage())
	if provider.HardwareAdmissionStatus() {
		t.Fatal("pending registration inherited fail-open admission")
	}
	if provider.PersistenceEnabled() {
		t.Fatal("pending registration enabled persistence before admission")
	}
}

func TestFleetGaugesExcludePendingAndRevokedProviders(t *testing.T) {
	reg := New(testLogger())
	reg.SetHardwareAdmissionEnforced(true)
	provider := reg.RegisterPendingHardwareAdmission(
		"gauge-admission", nil, testRegisterMessage())
	modelID := provider.Models[0].ID

	if reg.OnlineCount() != 0 || reg.ModelProviderSnapshot()[modelID] != 0 {
		t.Fatal("pending provider was counted as usable fleet capacity")
	}
	if !reg.CommitProviderHardwareAdmission(provider) {
		t.Fatal("failed to admit current provider")
	}
	if reg.OnlineCount() != 1 || reg.ModelProviderSnapshot()[modelID] != 1 {
		t.Fatal("admitted provider was absent from fleet gauges")
	}
	if !reg.SetProviderHardwareRevoked(provider, true) {
		t.Fatal("failed to revoke current provider")
	}
	if reg.OnlineCount() != 0 || reg.ModelProviderSnapshot()[modelID] != 0 {
		t.Fatal("revoked provider remained in usable fleet gauges")
	}
}

func TestExplicitRevocationFencesRoutingWhenThresholdGateDisabled(t *testing.T) {
	reg := New(testLogger())
	provider := reg.Register("revoked-disabled", nil, testRegisterMessage())
	if !reg.ProviderHardwareAdmitted(provider) {
		t.Fatal("disabled threshold gate should initially admit provider")
	}
	if !reg.SetProviderHardwareRevoked(provider, true) {
		t.Fatal("failed to apply live revocation")
	}
	if reg.ProviderHardwareAdmitted(provider) {
		t.Fatal("threshold rollback bypassed explicit revocation")
	}
}

func TestAdmissionCommitRejectsDisconnectedConnection(t *testing.T) {
	reg := New(testLogger())
	provider := reg.RegisterPendingHardwareAdmission(
		"disconnect-before-commit", nil, testRegisterMessage())
	reg.Disconnect(provider.ID)

	if reg.CommitProviderHardwareAdmission(provider) {
		t.Fatal("disconnected provider committed admission")
	}
	if provider.HardwareAdmissionStatus() || provider.PersistenceEnabled() {
		t.Fatal("stale provider gained admission or persistence")
	}
}

func TestStaleAdmissionCallbacksCannotMutateReplacementConnection(t *testing.T) {
	reg := New(testLogger())
	stale := reg.RegisterPendingHardwareAdmission(
		"reused-provider-id", nil, testRegisterMessage())
	reg.DisconnectProvider(stale)
	replacement := reg.RegisterPendingHardwareAdmission(
		stale.ID, nil, testRegisterMessage())

	if reg.SetProviderHardwareAdmitted(stale, true) {
		t.Fatal("stale callback mutated replacement admission")
	}
	if reg.ClaimProviderSerial(stale, "SERIAL-STALE") {
		t.Fatal("stale callback claimed a serial for replacement")
	}
	reg.DisconnectProvider(stale)
	if reg.GetProvider(replacement.ID) != replacement {
		t.Fatal("stale disconnect evicted replacement connection")
	}
	if replacement.HardwareAdmissionStatus() {
		t.Fatal("replacement inherited stale admission")
	}
}

func TestStaleTrustGrantCannotPromoteReplacementConnection(t *testing.T) {
	reg := New(testLogger())
	stale := reg.RegisterPendingHardwareAdmission(
		"reused-trust-id", nil, testRegisterMessage())
	reg.DisconnectProvider(stale)
	replacement := reg.RegisterPendingHardwareAdmission(
		stale.ID, nil, testRegisterMessage())

	if reg.GrantProviderHardwareIfCurrent(stale) {
		t.Fatal("stale MDM callback granted hardware trust")
	}
	if stale.GetTrustLevel() == TrustHardware {
		t.Fatal("stale provider pointer was promoted")
	}
	if !reg.GrantProviderHardwareIfCurrent(replacement) {
		t.Fatal("current provider did not receive hardware trust")
	}
}

func TestStaleConnectionCannotOverwriteReplacementPersistence(t *testing.T) {
	st := store.NewMemory(store.Config{})
	reg := New(testLogger())
	reg.SetStore(st)
	stale := reg.RegisterPendingHardwareAdmission(
		"reused-persistence-id", nil, testRegisterMessage())
	stale.mu.Lock()
	stale.persistenceEnabled = true
	stale.Attested = true
	stale.TrustLevel = TrustHardware
	stale.mu.Unlock()
	reg.DisconnectProvider(stale)
	replacement := reg.RegisterPendingHardwareAdmission(
		stale.ID, nil, testRegisterMessage())

	current, err := reg.PersistProviderSyncIfCurrent(
		context.Background(), stale)
	if err != nil {
		t.Fatalf("persist stale provider: %v", err)
	}
	if current {
		t.Fatal("stale provider was treated as the current connection")
	}
	if reg.GetProvider(replacement.ID) != replacement {
		t.Fatal("replacement connection was displaced")
	}
	rec, _ := st.GetProviderRecord(context.Background(), stale.ID)
	if rec != nil {
		t.Fatal("stale provider overwrote replacement durable state")
	}
}

func TestSlowPersistenceOnlyBlocksReplacementForSameProvider(t *testing.T) {
	memory := store.NewMemory(store.Config{})
	blocking := &blockingProviderUpsertStore{
		Store: memory, started: make(chan struct{}),
		second: make(chan struct{}), release: make(chan struct{}),
	}
	reg := New(testLogger())
	reg.SetStore(blocking)
	provider := reg.RegisterPendingHardwareAdmission(
		"slow-persistence", nil, testRegisterMessage())
	provider.mu.Lock()
	provider.persistenceEnabled = true
	provider.mu.Unlock()

	persisted := make(chan error, 1)
	go func() {
		_, err := reg.PersistProviderSyncIfCurrent(
			context.Background(), provider)
		persisted <- err
	}()
	<-blocking.started

	replacementStarted := make(chan struct{})
	replacementDone := make(chan *Provider, 1)
	go func() {
		close(replacementStarted)
		replacementDone <- reg.RegisterPendingHardwareAdmission(
			provider.ID, nil, testRegisterMessage())
	}()
	<-replacementStarted

	unrelatedDone := make(chan *Provider, 1)
	go func() {
		unrelatedDone <- reg.RegisterPendingHardwareAdmission(
			"unrelated-provider", nil, testRegisterMessage())
	}()
	select {
	case unrelated := <-unrelatedDone:
		if unrelated == nil {
			t.Fatal("unrelated registration returned nil")
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("slow persistence blocked an unrelated registry mutation")
	}
	select {
	case <-replacementDone:
		t.Fatal("same-ID replacement bypassed in-flight persistence")
	case <-time.After(25 * time.Millisecond):
	}

	close(blocking.release)
	if err := <-persisted; err != nil {
		t.Fatal(err)
	}
	replacement := <-replacementDone
	if reg.GetProvider(provider.ID) != replacement {
		t.Fatal("replacement did not become current after persistence completed")
	}
}

func TestSynchronousTrustGrantSupersedesOlderPersistence(t *testing.T) {
	memory := store.NewMemory(store.Config{})
	blocking := &blockingProviderUpsertStore{
		Store: memory, started: make(chan struct{}),
		second: make(chan struct{}), release: make(chan struct{}),
	}
	reg := New(testLogger())
	reg.SetStore(blocking)
	provider := reg.RegisterPendingHardwareAdmission(
		"serialized-persistence", nil, testRegisterMessage())
	provider.mu.Lock()
	provider.persistenceEnabled = true
	provider.Attested = true
	provider.TrustLevel = TrustSelfSigned
	provider.mu.Unlock()
	if err := memory.OpenProviderSession(
		context.Background(), provider.ID, "", ""); err != nil {
		t.Fatal(err)
	}

	persisted := make(chan error, 1)
	go func() {
		_, err := reg.PersistProviderSyncIfCurrent(
			context.Background(), provider)
		persisted <- err
	}()
	<-blocking.started

	type grantResult struct {
		ok  bool
		err error
	}
	granted := make(chan grantResult, 1)
	go func() {
		ok, err := reg.GrantProviderHardwareAndPersistIfCurrent(
			context.Background(), provider, true)
		granted <- grantResult{ok: ok, err: err}
	}()
	select {
	case <-blocking.second:
	case <-time.After(250 * time.Millisecond):
	}
	close(blocking.release)
	if err := <-persisted; err != nil {
		t.Fatal(err)
	}
	result := <-granted
	if result.err != nil || !result.ok {
		t.Fatalf("grant = (%v,%v), want true,nil", result.ok, result.err)
	}
	record, err := memory.GetProviderRecord(
		context.Background(), provider.ID)
	if err != nil {
		t.Fatal(err)
	}
	if record.TrustLevel != string(TrustHardware) || !record.Attested {
		t.Fatalf("durable trust = (%q,%v), want hardware,true",
			record.TrustLevel, record.Attested)
	}
}

func TestClaimProviderSerialKeepsFirstVerifiedOwner(t *testing.T) {
	reg := New(testLogger())
	first := reg.Register("first", nil, testRegisterMessage())
	second := reg.Register("second", nil, testRegisterMessage())
	first.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-CLAIM"})
	second.SetAttestationResult(&attestation.VerificationResult{SerialNumber: " serial-claim "})

	if !reg.ClaimProviderSerial(first, "SERIAL-CLAIM") {
		t.Fatal("first verified claimant did not acquire serial")
	}
	if reg.ClaimProviderSerial(second, "SERIAL-CLAIM") {
		t.Fatal("second claimant replaced live serial owner")
	}
	if reg.GetProvider(first.ID) == nil {
		t.Fatal("first serial owner was evicted")
	}
	if reg.GetProvider(second.ID) != nil {
		t.Fatal("duplicate serial claimant remained connected")
	}
}

func TestVerifiedSerialClaimReplacesLegacyOwnerMap(t *testing.T) {
	reg := New(testLogger())
	legacy := reg.Register("legacy-owner", nil, testRegisterMessage())
	verified := reg.Register("verified-owner", nil, testRegisterMessage())
	legacy.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-UPGRADE"})
	verified.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-UPGRADE"})

	reg.DisconnectDuplicatesBySerial(legacy, "SERIAL-UPGRADE")
	// Re-register the future verified claimant because legacy dedup intentionally
	// evicted the duplicate under pre-enforcement semantics.
	verified = reg.Register("verified-owner-2", nil, testRegisterMessage())
	verified.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-UPGRADE"})
	if !reg.ClaimProviderSerial(verified, "SERIAL-UPGRADE") {
		t.Fatal("legacy owner map blocked independently verified serial claim")
	}
	if reg.GetProvider(verified.ID) == nil {
		t.Fatal("verified owner was evicted by legacy serial state")
	}
	if reg.GetProvider(legacy.ID) != nil {
		t.Fatal("legacy serial owner survived verified replacement")
	}
}

func TestConcurrentVerifiedSerialClaimsLeaveOneOwner(t *testing.T) {
	for range 25 {
		reg := New(testLogger())
		first := reg.Register("first", nil, testRegisterMessage())
		second := reg.Register("second", nil, testRegisterMessage())
		first.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-RACE"})
		second.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-RACE"})

		start := make(chan struct{})
		results := make(chan bool, 2)
		var wg sync.WaitGroup
		for _, provider := range []*Provider{first, second} {
			wg.Add(1)
			go func(provider *Provider) {
				defer wg.Done()
				<-start
				results <- reg.ClaimProviderSerial(provider, "SERIAL-RACE")
			}(provider)
		}
		close(start)
		wg.Wait()
		close(results)
		successes := 0
		for result := range results {
			if result {
				successes++
			}
		}
		if successes != 1 {
			t.Fatalf("successful claims = %d, want exactly one", successes)
		}
		if reg.ProviderCount() != 1 {
			t.Fatalf("provider count = %d, want one owner", reg.ProviderCount())
		}
	}
}
