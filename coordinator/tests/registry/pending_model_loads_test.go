package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func newPendingLoadRegistry() (*production.Registry, *pendingload.Ledger, *production.ModelLoadPlanner) {
	ledger := &pendingload.Ledger{}
	var planner *production.ModelLoadPlanner
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		PendingLoads: ledger,
		ModelLoadPlanning: func(actual *production.ModelLoadPlanner) production.ModelLoadPlanning {
			planner = actual
			return actual
		},
	})
	return r, ledger, planner
}

func pendingLoadExpiry(ledger *pendingload.Ledger, providerID, modelID string) (time.Time, bool) {
	reservation, ok := ledger.Lookup(pendingload.Key{ProviderID: providerID, ModelID: modelID})
	return reservation.ExpiresAt, ok
}

func TestPendingModelLoadReserveAndExpiry(t *testing.T) {
	_, ledger, planner := newPendingLoadRegistry()
	now := time.Now()

	reserved := planner.Reserve([]production.ModelLoadAction{{ProviderID: "p1", ModelID: "m1"}}, now)
	if len(reserved) != 1 {
		t.Fatalf("expected 1 reserved action, got %d", len(reserved))
	}

	// While the entry lives, the provider must not be reserved again — not
	// even for a different model (single-slot swap oscillation guard).
	again := planner.Reserve([]production.ModelLoadAction{{ProviderID: "p1", ModelID: "m2"}}, now.Add(time.Minute))
	if len(again) != 0 {
		t.Fatal("provider with a pending load was reserved again")
	}

	planner.Expire(now.Add(pendingload.TTL - time.Second))
	if !ledger.HasProvider("p1") {
		t.Fatal("pending load expired before the TTL")
	}

	planner.Expire(now.Add(pendingload.TTL + time.Second))
	if ledger.HasProvider("p1") {
		t.Fatal("pending load survived past the TTL")
	}
}

func TestHasPendingModelLoadMatchesExactUnexpiredCommand(t *testing.T) {
	r, ledger, planner := newPendingLoadRegistry()
	if r.HasPendingModelLoad("p1", "m1") {
		t.Fatal("missing command reported as pending")
	}

	planner.Reserve([]production.ModelLoadAction{{ProviderID: "p1", ModelID: "m1"}}, time.Now())
	if !r.HasPendingModelLoad("p1", "m1") {
		t.Fatal("coordinator-issued command was not reported pending")
	}
	if r.HasPendingModelLoad("p1", "m2") || r.HasPendingModelLoad("p2", "m1") {
		t.Fatal("pending command matched a different provider/model pair")
	}

	key := pendingload.Key{ProviderID: "p1", ModelID: "m1"}
	reservation, _ := ledger.Lookup(key)
	ledger.Reserve(key, time.Now().Add(-time.Second), reservation.StartedAt)
	if r.HasPendingModelLoad("p1", "m1") {
		t.Fatal("expired command reported as pending")
	}
}

func TestDrainBackoffShortensPendingLoadCooldown(t *testing.T) {
	r, ledger, planner := newPendingLoadRegistry()
	planner.Reserve([]production.ModelLoadAction{{ProviderID: "p1", ModelID: "m1"}}, time.Now())

	// A drain rejection re-stamps the entry with the short backoff: long
	// enough to keep the planner off a provider that is about to restart,
	// short enough that an aborted restart leaves it plannable again well
	// inside the queue window.
	r.BackoffPendingModelLoadForDrain("p1", "m1")

	planner.Expire(time.Now().Add(pendingload.DrainBackoff - 5*time.Second))
	if !ledger.HasProvider("p1") {
		t.Fatal("drain backoff cleared too early")
	}

	planner.Expire(time.Now().Add(pendingload.DrainBackoff + time.Second))
	if ledger.HasProvider("p1") {
		t.Fatal("drain backoff survived past pendingModelLoadDrainBackoff")
	}
}

func TestDrainBackoffAppliesWithoutPriorReservation(t *testing.T) {
	// The coordinator may learn of a drain rejection for a load_model it sent
	// before a restart (entry already expired or cleared). The backoff must
	// still record the provider as temporarily unplannable.
	r, ledger, planner := newPendingLoadRegistry()
	r.BackoffPendingModelLoadForDrain("p1", "m1")

	if !ledger.HasProvider("p1") {
		t.Fatal("drain backoff did not create a pending entry")
	}

	planner.Expire(time.Now().Add(pendingload.DrainBackoff + time.Second))
	if ledger.HasProvider("p1") {
		t.Fatal("drain backoff survived past pendingModelLoadDrainBackoff")
	}
}

// TestMemoryBackoffShortensPendingLoadCooldown checks that a non-draining load
// failure (insufficient memory et al.) shortens the pending cooldown from the
// full 2-min TTL to the short memory backoff so a provider whose memory frees in
// seconds is reconsidered well inside the 120s queue window.
func TestMemoryBackoffShortensPendingLoadCooldown(t *testing.T) {
	r, ledger, planner := newPendingLoadRegistry()
	planner.Reserve([]production.ModelLoadAction{{ProviderID: "p1", ModelID: "m1"}}, time.Now())

	r.BackoffPendingModelLoadForMemory("p1", "m1")

	planner.Expire(time.Now().Add(pendingload.MemoryBackoff - 5*time.Second))
	if !ledger.HasProvider("p1") {
		t.Fatal("memory backoff cleared too early")
	}

	planner.Expire(time.Now().Add(pendingload.MemoryBackoff + time.Second))
	if ledger.HasProvider("p1") {
		t.Fatal("memory backoff survived past pendingModelLoadMemoryBackoff")
	}
}

// TestMemoryBackoffRestampsFullTTLEntry pins the re-stamp: a fresh reservation
// stamps now+pendingModelLoadTTL (2 min); the memory backoff must rewrite that
// expiry DOWN to ~now+pendingModelLoadMemoryBackoff (not merely clear it).
func TestMemoryBackoffRestampsFullTTLEntry(t *testing.T) {
	r, ledger, planner := newPendingLoadRegistry()
	planner.Reserve([]production.ModelLoadAction{{ProviderID: "p1", ModelID: "m1"}}, time.Now())

	full, ok := pendingLoadExpiry(ledger, "p1", "m1")
	if !ok {
		t.Fatal("reservation did not create a pending entry")
	}

	r.BackoffPendingModelLoadForMemory("p1", "m1")

	shortened, ok := pendingLoadExpiry(ledger, "p1", "m1")
	if !ok {
		t.Fatal("memory backoff dropped the pending entry")
	}
	if !shortened.Before(full) {
		t.Fatalf("memory backoff did not shorten expiry: full=%v shortened=%v", full, shortened)
	}
	if d := time.Until(shortened); d > pendingload.MemoryBackoff+2*time.Second {
		t.Fatalf("memory backoff expiry too far out: %v (want <= %v)", d, pendingload.MemoryBackoff)
	}
}

// TestMemoryBackoffAppliesWithoutPriorReservation mirrors the drain case: a
// failure status can arrive for a load whose reservation already expired/cleared.
func TestMemoryBackoffAppliesWithoutPriorReservation(t *testing.T) {
	r, ledger, planner := newPendingLoadRegistry()
	r.BackoffPendingModelLoadForMemory("p1", "m1")

	if !ledger.HasProvider("p1") {
		t.Fatal("memory backoff did not create a pending entry")
	}

	planner.Expire(time.Now().Add(pendingload.MemoryBackoff + time.Second))
	if ledger.HasProvider("p1") {
		t.Fatal("memory backoff survived past pendingModelLoadMemoryBackoff")
	}
}

// TestMemoryBackoffReapedByWarmPoolSweep proves the lazy reaper that runs every
// warm-pool tick (~10s), pendingModelLoadCount, drops the short entry once it
// expires so the provider becomes plannable again deterministically.
func TestMemoryBackoffReapedByWarmPoolSweep(t *testing.T) {
	ledger := &pendingload.Ledger{}
	r := newWarmRegistryWithDeps(t, func(deps *production.Dependencies) { deps.PendingLoads = ledger })
	r.ConfigureWarmPool(warmplan.Config{})
	planning := warmFixtureFor(r).deps
	r.BackoffPendingModelLoadForMemory("p1", "m1")

	if n := planning.PendingLoads(time.Now()); n != 1 {
		t.Fatalf("pendingModelLoadCount = %d before expiry, want 1", n)
	}
	if n := planning.PendingLoads(time.Now().Add(pendingload.MemoryBackoff + time.Second)); n != 0 {
		t.Fatalf("pendingModelLoadCount = %d after expiry, want 0 (warm-pool sweep must reap)", n)
	}
	if ledger.HasProvider("p1") {
		t.Fatal("warm-pool sweep did not reap the expired memory backoff")
	}
}

// TestDisconnectClearsPendingModelLoad pins the deterministic-clearing
// invariant: a provider going away must drop its pending model-load state
// (expiry and start time) so a reconnect starts clean and the planner is not suppressed.
func TestDisconnectClearsPendingModelLoad(t *testing.T) {
	r, ledger, planner := newPendingLoadRegistry()
	r.Register("p1", nil, testRegisterMessage())
	planner.Reserve([]production.ModelLoadAction{{ProviderID: "p1", ModelID: "m1"}}, time.Now())
	if !ledger.HasProvider("p1") {
		t.Fatal("reservation did not create a pending entry")
	}

	r.Disconnect("p1")

	if ledger.HasProvider("p1") {
		t.Fatal("Disconnect did not clear the provider's pending model load")
	}
	_, startedLeft := ledger.Lookup(pendingload.Key{ProviderID: "p1", ModelID: "m1"})
	if startedLeft {
		t.Fatal("Disconnect left a dangling pendingModelLoadStarted entry")
	}
}
