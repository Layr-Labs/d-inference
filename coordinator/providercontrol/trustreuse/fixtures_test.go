package trustreuse

import (
	"context"
	"errors"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"strings"
	"sync"
	"testing"
	"time"
)

type failingJournal struct {
	hardUntrustJournal
	appendErr error
	removeErr error
}

func (j *failingJournal) Append(entry hardUntrustJournalEntry) ([]hardUntrustJournalEntry, error) {
	if j.appendErr != nil {
		return nil, j.appendErr
	}
	return j.hardUntrustJournal.Append(entry)
}

func (j *failingJournal) Remove(entry hardUntrustJournalEntry) ([]hardUntrustJournalEntry, error) {
	if j.removeErr != nil {
		return nil, j.removeErr
	}
	return j.hardUntrustJournal.Remove(entry)
}

type trustReuseListFailureStore struct {
	store.Store
}

func (s *trustReuseListFailureStore) ListProviderTrustReuse(context.Context) ([]store.ProviderTrustReuse, error) {
	return nil, errors.New("simulated trust-reuse list outage")
}

func durableTrustReuseTestServer(t *testing.T, st store.Store, journalPath string) *testManager {
	t.Helper()
	logger := quietLogger()
	return newTestManager(registry.New(logger), st, Config{
		DurableTrustReuse:     true,
		TrustReuseJournalPath: journalPath,
	}, logger)
}

// dummyMDMClient returns a non-nil *mdm.Client (no network at construction) so
// tryTrustReuseFastSkip's "MDM configured" gate (FIX C) is satisfied in unit tests
// that don't stand up a fake MicroMDM server.
func dummyMDMClient() *mdm.Client {
	return mdm.NewClient("http://127.0.0.1:1", "test", quietLogger())
}

// flakyDeleteStore wraps a real store and fails the first failFirst revocation
// attempts, then delegates. Used to prove stable-event retry.
type flakyDeleteStore struct {
	store.Store
	mu          sync.Mutex
	failFirst   int
	deleteCalls int
}

func (f *flakyDeleteStore) RevokeProviderTrustReuse(ctx context.Context, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	f.mu.Lock()
	f.deleteCalls++
	n := f.deleteCalls
	f.mu.Unlock()
	if n <= f.failFirst {
		return store.ProviderTrustReuse{}, fmt.Errorf("simulated transient revoke failure #%d", n)
	}
	return f.Store.RevokeProviderTrustReuse(ctx, seKey, revocationEventID)
}

func (f *flakyDeleteStore) calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.deleteCalls
}

// upsertHookStore wraps a real store and runs onUpsert just BEFORE delegating the
// reuse-record upsert. It deterministically injects a hard untrust into the
// check-then-write window (between recordTrustReuse's pre-write epoch check and the
// upsert committing) to exercise the FIX 2 post-write recheck.
type upsertHookStore struct {
	store.Store
	onUpsert func()
}

func (s *upsertHookStore) UpsertProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse, generation uint64) (store.ProviderTrustReuseWriteResult, error) {
	if s.onUpsert != nil {
		s.onUpsert()
	}
	return s.Store.UpsertProviderTrustReuse(ctx, rec, generation)
}

func (s *upsertHookStore) RecoverProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse, generation uint64) (store.ProviderTrustReuseWriteResult, error) {
	if s.onUpsert != nil {
		s.onUpsert()
	}
	return s.Store.RecoverProviderTrustReuse(ctx, rec, generation)
}

// ambiguousRevokeStore commits the first revocation and loses its response.
// The retry must reuse the same event identity.
type ambiguousRevokeStore struct {
	store.Store
	mu        sync.Mutex
	committed bool
}

func (s *ambiguousRevokeStore) RevokeProviderTrustReuse(ctx context.Context, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	s.mu.Lock()
	first := !s.committed
	if first {
		s.committed = true
	}
	s.mu.Unlock()
	authoritative, err := s.Store.RevokeProviderTrustReuse(
		ctx, seKey, revocationEventID)
	if err == nil && first {
		return store.ProviderTrustReuse{}, fmt.Errorf("simulated lost revocation commit response")
	}
	return authoritative, err
}

// Two distinct, valid 64-char SHA-256 hex digests for binary-hash gate tests.
var (
	trHashA = strings.Repeat("a", 64)
	trHashB = strings.Repeat("b", 64)
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

func trustReuseServer(t *testing.T) (*testManager, store.Store) {
	t.Helper()
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := newTestManager(registry.New(logger), st, Config{}, logger)
	return srv, st
}

// newTrustReuseProvider registers a fresh, online (not-untrusted, epoch 0) provider
// with the given SE key + serial, for exercising recordTrustReuse's epoch-checked
// write-through (FIX A) and the late-SecurityInfo path (FIX B).
func newTrustReuseProvider(t *testing.T, srv *testManager, id, seKey, serial string) *registry.Provider {
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
func trustReuseFastSkipProvider(t *testing.T) (*testManager, *registry.Provider, *func() time.Time) {
	t.Helper()
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), Config{}, logger)
	srv.mdmClient = dummyMDMClient() // satisfy the FIX C "MDM configured" gate
	cur := time.Unix(1_700_000_000, 0)
	clock := func() time.Time { return cur }
	srv.cache.now = clock

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

func mustList(t *testing.T, st store.Store) []store.ProviderTrustReuse {
	t.Helper()
	rows, err := st.ListProviderTrustReuse(context.Background())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	return rows
}

// coveredReuseRecord is hardwareReuseRecord plus a coordinator-measured
// continuity watermark.
func coveredReuseRecord(seKey, serial, binaryHash string, provedAt, coveredAt time.Time) store.ProviderTrustReuse {
	rec := hardwareReuseRecord(seKey, serial, binaryHash, provedAt)
	rec.ContinuousCoverageUntil = &coveredAt
	return rec
}
