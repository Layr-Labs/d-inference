package registry

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// challengePersistCounter wraps the real in-memory store and counts the
// writes RecordChallengeSuccess can trigger (fault injection by decoration,
// not a mock: every call is delegated).
type challengePersistCounter struct {
	store.Store
	upsertProvider atomic.Int32
	touchSession   atomic.Int32
	upsertRep      atomic.Int32
}

func (c *challengePersistCounter) UpsertProvider(ctx context.Context, p store.ProviderRecord) error {
	c.upsertProvider.Add(1)
	return c.Store.UpsertProvider(ctx, p)
}

func (c *challengePersistCounter) TouchProviderSession(ctx context.Context, sessionID, serial, accountID, providerKey string, lastSeen time.Time) error {
	c.touchSession.Add(1)
	return c.Store.TouchProviderSession(ctx, sessionID, serial, accountID, providerKey, lastSeen)
}

func (c *challengePersistCounter) UpsertReputation(ctx context.Context, providerID string, rep store.ReputationRecord) error {
	c.upsertRep.Add(1)
	return c.Store.UpsertReputation(ctx, providerID, rep)
}

type challengeSuccessHarness struct {
	reg    *Registry
	st     *challengePersistCounter
	p      *Provider
	scans  atomic.Int32
	waiter *QueuedRequest
	// Registration persists the row itself (async); every assertion below is
	// a delta against the counts once that write has landed.
	baseUpsert, baseTouch, baseRep int32
}

const challengeSuccessModel = "mlx-community/Qwen3.5-9B-Instruct-4bit"

// newChallengeSuccessHarness registers one routable provider with a queued
// waiter for its model, so a drain pass is observable as a reservation scan.
func newChallengeSuccessHarness(t *testing.T) *challengeSuccessHarness {
	t.Helper()
	h := &challengeSuccessHarness{
		reg: New(testLogger()),
		st:  &challengePersistCounter{Store: store.NewMemory(store.Config{AdminKey: "k"})},
	}
	h.reg.SetStore(h.st)
	h.p = h.reg.Register("p1", nil, testRegisterMessage())
	h.p.mu.Lock()
	h.p.TrustLevel = TrustHardware
	h.p.mu.Unlock()
	deadline := time.Now().Add(2 * time.Second)
	for h.st.upsertProvider.Load() < 1 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	h.baseUpsert, h.baseTouch, h.baseRep = h.st.upsertProvider.Load(), h.st.touchSession.Load(), h.st.upsertRep.Load()
	h.reg.reservationAfterScan = func(string) { h.scans.Add(1) }
	h.waiter = &QueuedRequest{RequestID: "waiting", Model: challengeSuccessModel, ResponseCh: make(chan *Provider, 1)}
	h.reg.Queue().Enqueue(h.waiter)
	return h
}

// upserts / touches / reps are the writes since registration settled.
func (h *challengeSuccessHarness) upserts() int32 { return h.st.upsertProvider.Load() - h.baseUpsert }
func (h *challengeSuccessHarness) touches() int32 { return h.st.touchSession.Load() - h.baseTouch }
func (h *challengeSuccessHarness) reps() int32    { return h.st.upsertRep.Load() - h.baseRep }

func (h *challengeSuccessHarness) setFreshness(verified time.Time, sip bool) {
	h.p.mu.Lock()
	h.p.LastChallengeVerified = verified
	h.p.ChallengeVerifiedSIP = sip
	h.p.mu.Unlock()
}

// awaitWrites waits for the async persist goroutines to settle.
func (h *challengeSuccessHarness) awaitWrites(wantUpserts int32) {
	deadline := time.Now().Add(2 * time.Second)
	for h.upserts() < wantUpserts && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(150 * time.Millisecond) // let any unexpected extra write land
}

// TestRecordChallengeSuccessSteadyStateSkipsFullPersistAndDrain: a success on
// an already-fresh, already-SIP-verified provider writes no provider row, no
// session touch, and runs no queue drain; its reputation persist is throttled
// to one per 30 s.
func TestRecordChallengeSuccessSteadyStateSkipsFullPersistAndDrain(t *testing.T) {
	h := newChallengeSuccessHarness(t)
	h.setFreshness(time.Now(), true)

	h.reg.RecordChallengeSuccess("p1")
	h.reg.RecordChallengeSuccess("p1")
	h.awaitWrites(0)

	if got := h.upserts(); got != 0 {
		t.Errorf("UpsertProvider calls = %d, want 0 for a steady-state success (the heartbeat persist carries LastChallengeVerified)", got)
	}
	if got := h.touches(); got != 0 {
		t.Errorf("TouchProviderSession calls = %d, want 0", got)
	}
	if got := h.scans.Load(); got != 0 {
		t.Errorf("reservation scans = %d, want 0 (nothing transitioned, no drain)", got)
	}
	deadline := time.Now().Add(time.Second)
	for h.reps() < 1 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := h.reps(); got != 1 {
		t.Errorf("UpsertReputation calls = %d, want exactly 1 (throttled to one per 30 s)", got)
	}
	// Freshness is still advanced in memory.
	h.p.mu.Lock()
	verified := h.p.LastChallengeVerified
	h.p.mu.Unlock()
	if time.Since(verified) > time.Second {
		t.Errorf("LastChallengeVerified was not refreshed in memory")
	}
}

// TestRecordChallengeSuccessFirstSuccessFlipsSIPGateAndDrains: registration
// stamps LastChallengeVerified=now (the provider is immediately routable for
// plain text) but ChallengeVerifiedSIP starts false, so the FIRST success is a
// transition — it unlocks the private-text gate — and must persist and drain
// even though the freshness looks fresh.
func TestRecordChallengeSuccessFirstSuccessFlipsSIPGateAndDrains(t *testing.T) {
	h := newChallengeSuccessHarness(t)
	h.setFreshness(time.Now(), false)

	h.reg.RecordChallengeSuccess("p1")
	h.awaitWrites(1)

	if got := h.upserts(); got != 1 {
		t.Errorf("UpsertProvider calls = %d, want 1 on the first success", got)
	}
	if got := h.scans.Load(); got == 0 {
		t.Error("first success did not drain the queue (a waiter gated on SIP would sleep until the heartbeat drain)")
	}
	h.p.mu.Lock()
	sip := h.p.ChallengeVerifiedSIP
	h.p.mu.Unlock()
	if !sip {
		t.Error("ChallengeVerifiedSIP not set")
	}
}

// TestRecordChallengeSuccessStaleFreshnessPersistsAndDrains: a success on a
// provider whose challenge freshness lapsed (or was never set) is a
// transition for the liveness gate's challenge-age check.
func TestRecordChallengeSuccessStaleFreshnessPersistsAndDrains(t *testing.T) {
	for name, verified := range map[string]time.Time{
		"stale": time.Now().Add(-challengeFreshnessMaxAge - time.Minute),
		"never": {},
	} {
		t.Run(name, func(t *testing.T) {
			h := newChallengeSuccessHarness(t)
			h.setFreshness(verified, true)
			h.reg.RecordChallengeSuccess("p1")
			h.awaitWrites(1)
			if got := h.upserts(); got != 1 {
				t.Errorf("UpsertProvider calls = %d, want 1", got)
			}
			if h.scans.Load() == 0 {
				t.Error("stale-freshness success did not drain the queue")
			}
		})
	}
}

// TestRecordChallengeSuccessRecoveryPersistsAndDrains: recovery from a
// transient deroute is a transition regardless of freshness.
func TestRecordChallengeSuccessRecoveryPersistsAndDrains(t *testing.T) {
	h := newChallengeSuccessHarness(t)
	h.setFreshness(time.Now(), true)
	h.reg.MarkUntrustedTransient("p1")

	if !h.reg.RecordChallengeSuccess("p1") {
		t.Fatal("RecordChallengeSuccess must report recovery")
	}
	h.awaitWrites(1)
	if got := h.upserts(); got != 1 {
		t.Errorf("UpsertProvider calls = %d, want 1 on recovery", got)
	}
	if h.scans.Load() == 0 {
		t.Error("recovery did not drain the queue")
	}
	// A follow-up success is steady state again: no second row write.
	if h.reg.RecordChallengeSuccess("p1") {
		t.Fatal("second success must not report recovery")
	}
	h.awaitWrites(1)
	if got := h.upserts(); got != 1 {
		t.Errorf("UpsertProvider calls after a steady-state follow-up = %d, want still 1", got)
	}
}

var _ = protocol.TypeRegister
