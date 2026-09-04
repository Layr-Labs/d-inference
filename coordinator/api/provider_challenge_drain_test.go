package api

import (
	"context"
	"log/slog"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// challengeDrainUpsertCounter counts provider-row writes through the real
// in-memory store (decoration, not a mock: every call is delegated).
type challengeDrainUpsertCounter struct {
	store.Store
	upserts atomic.Int32
}

func (c *challengeDrainUpsertCounter) UpsertProvider(ctx context.Context, p store.ProviderRecord) error {
	c.upserts.Add(1)
	return c.Store.UpsertProvider(ctx, p)
}

// firstChallengeHarness registers ONE provider the way the /ws/provider
// handler does (Register, then verifyProviderAttestation — which stamps
// LastChallengeVerified=now so the provider is routable before its first
// challenge, while ChallengeVerifiedSIP starts false), makes it routable, and
// parks a queued request for its model. No trust-reuse record is seeded, so
// the fast-skip grant drain of trust_reuse_test cannot mask the challenge
// path's own drain.
type firstChallengeHarness struct {
	srv    *Server
	reg    *registry.Registry
	st     *challengeDrainUpsertCounter
	p      *registry.Provider
	pubKey string
	waiter *registry.QueuedRequest
	base   int32
}

const firstChallengeModel = "first-challenge-drain-model"

func newFirstChallengeHarness(t *testing.T) *firstChallengeHarness {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := &challengeDrainUpsertCounter{Store: store.NewMemory(store.Config{AdminKey: "test-key"})}
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: firstChallengeModel, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		DecodeTPS:               90,
		PrefillTPS:              900,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSON(t, pubKey),
	}
	p := reg.Register("prov-first-challenge", nil, regMsg)
	srv.verifyProviderAttestation("prov-first-challenge", p, regMsg)
	if p.GetLastChallengeVerified().IsZero() {
		t.Fatal("registration attestation must stamp LastChallengeVerified (the provider is routable before its first challenge)")
	}
	if p.GetChallengeVerifiedSIP() {
		t.Fatal("ChallengeVerifiedSIP must start false at registration")
	}
	reg.SetTrustLevel(p.ID, registry.TrustHardware)
	p.Mu().Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: firstChallengeModel, State: "running"}},
	}
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.Mu().Unlock()

	// Let registration's own async persist settle before taking the baseline.
	deadline := time.Now().Add(2 * time.Second)
	for st.upserts.Load() < 1 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)

	waiter := &registry.QueuedRequest{
		RequestID:  "queued-first-challenge",
		Model:      firstChallengeModel,
		ResponseCh: make(chan *registry.Provider, 1),
		Pending: &registry.PendingRequest{
			RequestID: "queued-first-challenge", Model: firstChallengeModel,
			RequestedMaxTokens: 256, EstimatedPromptTokens: 50,
		},
	}
	if err := reg.Queue().Enqueue(waiter); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	return &firstChallengeHarness{srv: srv, reg: reg, st: st, p: p, pubKey: pubKey, waiter: waiter, base: st.upserts.Load()}
}

// passChallenge drives verifyChallengeResponse with a valid response — the
// production caller of RecordChallengeSuccess — optionally carrying fresh
// per-model weight hashes.
func (h *firstChallengeHarness) passChallenge(t *testing.T, nonce string, hashes map[string]string) {
	t.Helper()
	sipEnabled, secureBootEnabled, rdmaDisabled := true, true, true
	const ts = "2026-04-24T12:00:00Z"
	h.srv.verifyChallengeResponse(h.p.ID, h.p, &pendingChallenge{nonce: nonce, timestamp: ts},
		&protocol.AttestationResponseMessage{
			Type:              protocol.TypeAttestationResponse,
			Nonce:             nonce,
			Signature:         testChallengeSignature(nonce, ts, h.pubKey),
			PublicKey:         h.pubKey,
			SIPEnabled:        &sipEnabled,
			SecureBootEnabled: &secureBootEnabled,
			RDMADisabled:      &rdmaDisabled,
			ModelHashes:       hashes,
		})
	h.p.Mu().Lock()
	status, failed := h.p.Status, h.p.FailedChallenges
	h.p.Mu().Unlock()
	if status == registry.StatusUntrusted || failed != 0 {
		t.Fatalf("challenge must pass in this harness (status=%s failed=%d)", status, failed)
	}
}

func (h *firstChallengeHarness) upserts() int32 { return h.st.upserts.Load() - h.base }

func (h *firstChallengeHarness) awaitUpserts(want int32) {
	deadline := time.Now().Add(2 * time.Second)
	for h.upserts() < want && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(150 * time.Millisecond)
}

func (h *firstChallengeHarness) requireDrained(t *testing.T, what string) {
	t.Helper()
	select {
	case assigned := <-h.waiter.ResponseCh:
		if assigned == nil || assigned.ID != h.p.ID {
			t.Fatalf("%s: waiter assigned to %+v, want %s", what, assigned, h.p.ID)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("%s: the queued request was not drained (it would wait for the next heartbeat drain or the queue timeout)", what)
	}
}

func (h *firstChallengeHarness) requireNotDrained(t *testing.T, what string) {
	t.Helper()
	select {
	case assigned := <-h.waiter.ResponseCh:
		t.Fatalf("%s: waiter was drained to %+v, want no drain", what, assigned)
	case <-time.After(300 * time.Millisecond):
	}
}

// TestFirstChallengeSuccessAfterRegistrationDrainsQueue: on the production
// call path (verifyChallengeResponse -> RecordChallengeSuccess) the FIRST
// challenge success after (re)connect is the transition that flips
// ChallengeVerifiedSIP, so it must persist the row and drain the model
// queue. Before the fix verifyChallengeResponse wrote ChallengeVerifiedSIP=true
// itself before calling RecordChallengeSuccess, so the transition predicate
// saw prevSIP=true on a fresh registration and neither persisted nor drained:
// a waiter gated on the SIP flip slept until the next heartbeat drain.
func TestFirstChallengeSuccessAfterRegistrationDrainsQueue(t *testing.T) {
	h := newFirstChallengeHarness(t)

	h.passChallenge(t, "nonce-first", nil)

	h.requireDrained(t, "first challenge after registration")
	if !h.p.GetChallengeVerifiedSIP() {
		t.Fatal("first success must flip ChallengeVerifiedSIP")
	}
	h.awaitUpserts(1)
	if got := h.upserts(); got != 1 {
		t.Fatalf("UpsertProvider calls on the first success = %d, want 1 (the SIP flip must reach the store)", got)
	}
}

// TestSteadyStateChallengeSuccessSkipsDrainOnProductionPath: the second
// success on the same connection (fresh, SIP already verified, hashes
// unchanged) is steady state — no row write, no drain — so the T11-09
// suppression still holds on the real path once the first success transitions.
func TestSteadyStateChallengeSuccessSkipsDrainOnProductionPath(t *testing.T) {
	h := newFirstChallengeHarness(t)
	h.passChallenge(t, "nonce-first", nil)
	h.requireDrained(t, "first challenge")
	h.awaitUpserts(1)
	base := h.upserts()

	// Re-park a waiter, then a steady-state success.
	h.waiter = &registry.QueuedRequest{
		RequestID:  "queued-steady",
		Model:      firstChallengeModel,
		ResponseCh: make(chan *registry.Provider, 1),
		Pending: &registry.PendingRequest{
			RequestID: "queued-steady", Model: firstChallengeModel,
			RequestedMaxTokens: 256, EstimatedPromptTokens: 50,
		},
	}
	if err := h.reg.Queue().Enqueue(h.waiter); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	h.passChallenge(t, "nonce-second", nil)
	h.requireNotDrained(t, "steady-state challenge")
	h.awaitUpserts(base)
	if got := h.upserts(); got != base {
		t.Fatalf("UpsertProvider calls after a steady-state success = %d, want still %d", got, base)
	}
}

// TestChallengeWeightHashRefreshDrainsQueue: a success whose response carries
// a CHANGED per-model weight hash is a routing transition even in steady
// state (the catalog filter admits queued requests against the hash the
// response just proved), so it drains the queue. Before the fix
// UpdateModelWeightHashes discarded its own "changed" verdict and
// RecordChallengeSuccess treated the success as steady state.
func TestChallengeWeightHashRefreshDrainsQueue(t *testing.T) {
	h := newFirstChallengeHarness(t)
	h.passChallenge(t, "nonce-first", map[string]string{firstChallengeModel: "hash-a"})
	h.requireDrained(t, "first challenge")
	h.awaitUpserts(1)

	h.waiter = &registry.QueuedRequest{
		RequestID:  "queued-hash",
		Model:      firstChallengeModel,
		ResponseCh: make(chan *registry.Provider, 1),
		Pending: &registry.PendingRequest{
			RequestID: "queued-hash", Model: firstChallengeModel,
			RequestedMaxTokens: 256, EstimatedPromptTokens: 50,
		},
	}
	if err := h.reg.Queue().Enqueue(h.waiter); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	// Same hash: steady state, no drain.
	h.passChallenge(t, "nonce-same", map[string]string{firstChallengeModel: "hash-a"})
	h.requireNotDrained(t, "unchanged weight hash")
	// Changed hash: transition, drain.
	h.passChallenge(t, "nonce-changed", map[string]string{firstChallengeModel: "hash-b"})
	h.requireDrained(t, "changed weight hash")
}
