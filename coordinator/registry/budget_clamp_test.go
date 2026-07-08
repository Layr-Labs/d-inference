package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Tests for the gray-box budget clamp (budget_clamp.go): after ONE
// capacity-shaped 503, admission stops believing the pair's stale-optimistic
// heartbeat budget and treats the slot as full; release requires provider-side
// proof (a strictly-fresher heartbeat with meaningful headroom AND an accept),
// with a TTL fail-open so a missed release path can never strand a slot.
// Regression suite for the 2026-07 gray-box incident: 11,581 capacity 503s in
// 6h from boxes whose heartbeats reported ~1.4% budget used while their live
// KV gates rejected — invisible to every zero-interleaved-accepts breaker
// because the boxes also served ~60% of dispatches.

// grayBoxBudget mirrors the incident heartbeat: ~72k used of ~5.2M advertised.
const (
	grayBoxBudgetUsed = int64(72_000)
	grayBoxBudgetMax  = int64(5_200_000)
)

// sendBudgetHeartbeat drives the REAL heartbeat path (the same one prod
// heartbeats take), delivering a fresh BackendCapacity snapshot with the given
// slot budget. LastHeartbeat and BackendCapacity are stamped in the same
// critical section, which is exactly the freshness anchor the clamp release
// compares against.
func sendBudgetHeartbeat(r *Registry, providerID, model string, used, max int64) {
	active := model
	r.Heartbeat(providerID, &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "idle",
		ActiveModel: &active,
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal",
		},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{{
				Model:                 model,
				State:                 "running",
				ActiveTokenBudgetUsed: used,
				ActiveTokenBudgetMax:  max,
			}},
		},
	})
}

// reserveOnce runs the production reservation path once and releases the
// reservation, returning the selected provider (nil = no route) and decision.
func reserveOnce(r *Registry, model, requestID string) (*Provider, RoutingDecision) {
	p, decision := r.ReserveProviderEx(model, &PendingRequest{
		RequestID:             requestID,
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    256,
	})
	if p != nil {
		p.RemovePending(requestID)
		r.SetProviderIdle(p.ID)
	}
	return p, decision
}

// ageBudgetClamp rewinds the pair's clamp time by d (simulating TTL passage
// without sleeping), keyed by the pair's CURRENT fault key.
func ageBudgetClamp(r *Registry, providerID, model string, d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: model}
	if e, ok := r.budgetClamps[key]; ok {
		e.clampedAt = e.clampedAt.Add(-d)
	}
}

// One capacity-503 must IMMEDIATELY stop admission for a request that fit
// moments earlier — the heartbeat still advertises ~5.1M free tokens, but the
// provider's live gate just proved it rejects. The rejection must read as
// TRANSIENT capacity (429/queue material), not structural absence, on both the
// routing decision and the preflight.
func TestBudgetClampBlocksAdmissionOnFirstCapacityReject(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "gray-box", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	if sel, _ := reserveOnce(r, model, "pre-clamp"); sel == nil {
		t.Fatal("setup: request must fit the advertised budget before the clamp")
	}

	if r.RecordCapacityReject(p.ID, model) {
		t.Fatal("one reject must not trip the pair cooldown (threshold 5) — the clamp is the fast path")
	}
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("clamp must be active after one capacity reject")
	}
	sel, decision := reserveOnce(r, model, "post-clamp")
	if sel != nil {
		t.Fatalf("clamped pair was admitted (provider %s) — admission believed the stale heartbeat budget", sel.ID)
	}
	if decision.CapacityRejections != 1 {
		t.Fatalf("decision.CapacityRejections = %d, want 1 (clamp is transient capacity, not structural absence)", decision.CapacityRejections)
	}
	cc, capRej, _ := r.QuickCapacityCheck(model, 500, 256, RequestTraits{})
	if cc != 0 || capRej != 1 {
		t.Fatalf("preflight (candidates=%d, capacityRejections=%d), want (0, 1) — preflight must mirror routing", cc, capRej)
	}
}

// The clamp releases ONLY on provider-side proof: an accept alone (in-flight
// request committing content) is not enough while the freshest heartbeat still
// predates the clamp, and a fresh heartbeat alone is not enough without an
// accept. Both together — in either order — release.
func TestBudgetClampReleaseRequiresFreshHeartbeatAndAccept(t *testing.T) {
	const model = "gemma-4-26b-qat-4bit"

	t.Run("accept then heartbeat", func(t *testing.T) {
		r := New(testLogger())
		p := makeTokenBudgetProvider(t, r, "gray-1", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)
		r.RecordCapacityReject(p.ID, model)

		// Accept lands (an in-flight request committed content), but the only
		// budget snapshot the coordinator holds STILL predates the clamp — the
		// stale-optimistic view must not admit again.
		r.RecordCapacityAccept(p.ID, model)
		if !r.BudgetClampActive(p.ID, model) {
			t.Fatal("accept with a stale (pre-clamp) heartbeat must NOT release the clamp")
		}
		if sel, _ := reserveOnce(r, model, "still-clamped"); sel != nil {
			t.Fatal("admission resumed on a stale heartbeat")
		}

		// A strictly-fresher heartbeat with meaningful headroom completes the
		// proof: release.
		time.Sleep(2 * time.Millisecond)
		sendBudgetHeartbeat(r, p.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
		if r.BudgetClampActive(p.ID, model) {
			t.Fatal("fresh heartbeat + prior accept must release the clamp")
		}
		if sel, _ := reserveOnce(r, model, "released"); sel == nil {
			t.Fatal("released pair must be admittable again")
		}
	})

	t.Run("heartbeat then accept", func(t *testing.T) {
		r := New(testLogger())
		p := makeTokenBudgetProvider(t, r, "gray-2", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)
		r.RecordCapacityReject(p.ID, model)

		time.Sleep(2 * time.Millisecond)
		sendBudgetHeartbeat(r, p.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
		if !r.BudgetClampActive(p.ID, model) {
			t.Fatal("a fresh optimistic heartbeat ALONE must not release the clamp — that heartbeat is exactly what the clamp distrusts")
		}
		if sel, _ := reserveOnce(r, model, "hb-only"); sel != nil {
			t.Fatal("admission resumed without an accept")
		}

		r.RecordCapacityAccept(p.ID, model)
		if r.BudgetClampActive(p.ID, model) {
			t.Fatal("accept after a fresh heartbeat must release the clamp (whichever proof comes later wins)")
		}
		if sel, _ := reserveOnce(r, model, "released-2"); sel == nil {
			t.Fatal("released pair must be admittable again")
		}
	})
}

// A post-clamp heartbeat that merely restates the pressure (raw remaining
// below the meaningful-headroom floor) must not release even with an accept:
// the box is serving what it has but has no room for more.
func TestBudgetClampNoMeaningfulHeadroomDoesNotRelease(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "gray-tight", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	r.RecordCapacityReject(p.ID, model)
	r.RecordCapacityAccept(p.ID, model)
	time.Sleep(2 * time.Millisecond)
	// Fresh heartbeat, but used ≈ max: remaining 512 < the 1024-token floor.
	sendBudgetHeartbeat(r, p.ID, model, 99_488, 100_000)
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("a pressure-restating heartbeat (remaining < 1024) must not release the clamp")
	}

	// The next heartbeat with real headroom releases (accept proof persists).
	sendBudgetHeartbeat(r, p.ID, model, 10_000, 100_000)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("meaningful headroom + accept must release")
	}
}

// FAIL OPEN: a clamp whose release path never completes (zero traffic → zero
// accepts) expires after the TTL, so a slot can never be stranded. A
// subsequent reject re-arms it.
func TestBudgetClampTTLFailOpen(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "gray-ttl", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	r.RecordCapacityReject(p.ID, model)
	if sel, _ := reserveOnce(r, model, "clamped"); sel != nil {
		t.Fatal("setup: clamp must block")
	}
	ageBudgetClamp(r, p.ID, model, defaultBudgetClampTTL+time.Second)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("clamp must fail open after its TTL")
	}
	if sel, _ := reserveOnce(r, model, "ttl-open"); sel == nil {
		t.Fatal("TTL-expired clamp must admit again with no accept/heartbeat proof")
	}
	// A fresh capacity-503 re-arms immediately.
	r.RecordCapacityReject(p.ID, model)
	if sel, _ := reserveOnce(r, model, "re-armed"); sel != nil {
		t.Fatal("post-TTL reject must re-arm the clamp")
	}
}

// A re-reject after release is fresh evidence: the clamp re-arms with a new
// clamp time, so the heartbeat that released the PREVIOUS clamp is stale for
// the new one and the accept proof starts over.
func TestBudgetClampReArmResetsReleaseProof(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "gray-reclamp", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	// Clamp → full release.
	r.RecordCapacityReject(p.ID, model)
	r.RecordCapacityAccept(p.ID, model)
	time.Sleep(2 * time.Millisecond)
	sendBudgetHeartbeat(r, p.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("setup: clamp must have released")
	}

	// Re-reject: the release-time heartbeat and accept must not carry over.
	time.Sleep(2 * time.Millisecond)
	r.RecordCapacityReject(p.ID, model)
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("re-reject must re-arm the clamp with fresh proof requirements")
	}
	if sel, _ := reserveOnce(r, model, "re-clamped"); sel != nil {
		t.Fatal("re-armed clamp must block admission")
	}
}

// Kill switch: EIGENINFERENCE_BUDGET_CLAMP=false restores the old behavior —
// a capacity reject leaves admission believing the heartbeat budget (only the
// threshold-5 pair cooldown remains, which one reject cannot trip).
func TestBudgetClampKillSwitch(t *testing.T) {
	t.Setenv(envBudgetClamp, "false")
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "gray-off", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	r.RecordCapacityReject(p.ID, model)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("disabled clamp reads active")
	}
	if sel, _ := reserveOnce(r, model, "kill-switch"); sel == nil {
		t.Fatal("with the clamp disabled, one reject must not block admission (old behavior)")
	}
}

// SCOPE: the clamp only overrides token-budget admission. A legacy provider
// whose slot reports no budget keeps the existing protections (pair cooldown
// at threshold 5) — one 503 must not gate it.
func TestBudgetClampLegacyBudgetlessProviderNotClamped(t *testing.T) {
	r := New(testLogger())
	const model = "legacy-model"
	p := makeSchedulerProvider(t, r, "legacy-box", model, 100) // no ActiveTokenBudgetMax

	r.RecordCapacityReject(p.ID, model)
	if sel, _ := reserveOnce(r, model, "legacy"); sel == nil {
		t.Fatal("a budget-less provider must not be admission-gated by a single capacity reject")
	}
}

// The clamp keys by STABLE identity: a disconnect/reconnect with the same
// serial (fresh session UUID) must not shed it — the reconnect exploit that
// wiped every session-keyed breaker must stay closed for the clamp too.
func TestBudgetClampSurvivesReconnect(t *testing.T) {
	r := New(testLogger())
	const model, serial = "gemma-4-26b-qat-4bit", "SER-CLAMP"

	p1 := attestSchedulerProvider(t, r, "clamp-sess-1", model, serial, 100)
	p1.mu.Lock()
	p1.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = grayBoxBudgetUsed
	p1.BackendCapacity.Slots[0].ActiveTokenBudgetMax = grayBoxBudgetMax
	p1.mu.Unlock()

	r.RecordCapacityReject(p1.ID, model)
	if !r.BudgetClampActive(p1.ID, model) {
		t.Fatal("setup: clamp must be active")
	}
	r.Disconnect("clamp-sess-1")

	p2 := attestSchedulerProvider(t, r, "clamp-sess-2", model, serial, 100)
	p2.mu.Lock()
	p2.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = grayBoxBudgetUsed
	p2.BackendCapacity.Slots[0].ActiveTokenBudgetMax = grayBoxBudgetMax
	p2.mu.Unlock()

	if !r.BudgetClampActive(p2.ID, model) {
		t.Fatal("clamp must re-attach to the reconnected session via the stable fault key")
	}
	if sel, _ := reserveOnce(r, model, "reconnect"); sel != nil {
		t.Fatal("reconnect must not shed the clamp — admission resumed")
	}
	// Release still works through the new session: accept + fresh heartbeat.
	r.RecordCapacityAccept(p2.ID, model)
	time.Sleep(2 * time.Millisecond)
	sendBudgetHeartbeat(r, p2.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
	if r.BudgetClampActive(p2.ID, model) {
		t.Fatal("release proof through the reconnected session must lift the clamp")
	}
}

// Clamp + rate state must MIGRATE on an identity (re)bind: strikes recorded
// pre-attestation live under the session fallback key and must follow the
// stable identity when attestation binds — otherwise a gray box sheds its
// record at the exact moment its identity improves.
func TestBudgetClampAndRateStateMigrateOnFirstBind(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "migrate-sess", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	// Session-keyed clamp + rate outcomes (no attestation yet).
	r.RecordCapacityReject(p.ID, model)
	r.RecordCapacityAcceptOutcome(p.ID, model, true)

	// Attestation binds session → serial; state must migrate.
	setAttestationAndBind(t, r, p, "SER-MIG-CLAMP")

	r.mu.RLock()
	sessKey := capacityRejectKey{ProviderID: "migrate-sess", ModelID: model}
	serialKey := capacityRejectKey{ProviderID: "serial:SER-MIG-CLAMP", ModelID: model}
	_, sessClamp := r.budgetClamps[sessKey]
	_, serialClamp := r.budgetClamps[serialKey]
	sessRejects := len(r.capacityRateRejects[sessKey])
	serialRejects := len(r.capacityRateRejects[serialKey])
	serialAccepts := len(r.capacityRateAccepts[serialKey])
	r.mu.RUnlock()

	if sessClamp || sessRejects > 0 {
		t.Fatal("session-keyed gray-box state orphaned after the identity bind")
	}
	if !serialClamp {
		t.Fatal("budget clamp did not migrate to the stable identity")
	}
	if serialRejects != 1 || serialAccepts != 1 {
		t.Fatalf("rate window did not migrate: rejects=%d accepts=%d, want 1/1", serialRejects, serialAccepts)
	}
	// And the clamp still gates the (unchanged) session id via faultKeyLocked.
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("migrated clamp must still gate the live session")
	}
}

// Race coverage: reserves (which read clamp + rate state under selection
// locks), capacity rejects/accepts (which write it), and real heartbeats (which
// replace BackendCapacity and stamp the freshness anchor) all running
// concurrently must be data-race-free and never panic. Run with -race.
func TestBudgetClampAndRateConcurrentAccess(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "race-box", model, 100, 0, grayBoxBudgetMax, 100)
	makeTokenBudgetProvider(t, r, "race-peer", model, 50, 0, 200_000, 50)

	done := make(chan struct{})
	var wg sync.WaitGroup
	worker := func(fn func(i int)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; ; i++ {
				select {
				case <-done:
					return
				default:
					fn(i)
				}
			}
		}()
	}
	worker(func(i int) { r.RecordCapacityReject(p.ID, model) })
	worker(func(i int) {
		r.RecordCapacityAcceptOutcome(p.ID, model, i%2 == 0)
	})
	worker(func(i int) { sendBudgetHeartbeat(r, p.ID, model, int64(i%1000), grayBoxBudgetMax) })
	worker(func(i int) { r.BudgetClampActive(p.ID, model) })
	worker(func(i int) { r.CapacityRejectRate(p.ID, model) })
	worker(func(i int) {
		rid := fmt.Sprintf("race-%d", i)
		if sel, _ := r.ReserveProviderEx(model, &PendingRequest{
			RequestID: rid, Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 64,
		}); sel != nil {
			sel.RemovePending(rid)
			r.SetProviderIdle(sel.ID)
		}
	})
	worker(func(i int) { r.QuickCapacityCheck(model, 100, 64, RequestTraits{}) })

	time.Sleep(150 * time.Millisecond)
	close(done)
	wg.Wait()
}

// A RELEASED clamp's entry must not linger and revive as a block on the
// identity's next reconnect (Codex review of #523, round 3): before the fix
// the released entry stayed in budgetClamps, and the reconnected session's
// budgetless pre-heartbeat window read map presence as an active clamp —
// re-blocking a pair that had already proven recovery. Covers both release
// orders (the heartbeat sweep and the accept-path drop).
func TestBudgetClampReleasedEntryDoesNotReviveOnReconnect(t *testing.T) {
	const model = "gemma-4-26b-qat-4bit"

	run := func(t *testing.T, serial, sess1, sess2 string, release func(r *Registry, providerID string)) {
		t.Helper()
		r := New(testLogger())
		p1 := attestSchedulerProvider(t, r, sess1, model, serial, 100)
		p1.mu.Lock()
		p1.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = grayBoxBudgetUsed
		p1.BackendCapacity.Slots[0].ActiveTokenBudgetMax = grayBoxBudgetMax
		p1.mu.Unlock()

		r.RecordCapacityReject(p1.ID, model)
		if !r.BudgetClampActive(p1.ID, model) {
			t.Fatal("setup: clamp must be active")
		}
		release(r, p1.ID)
		if r.BudgetClampActive(p1.ID, model) {
			t.Fatal("setup: clamp must have released")
		}
		r.mu.RLock()
		_, lingering := r.budgetClamps[capacityRejectKey{ProviderID: "serial:" + serial, ModelID: model}]
		r.mu.RUnlock()
		if lingering {
			t.Fatal("released clamp entry must be deleted, not linger in budgetClamps")
		}

		// Reconnect before the original TTL, budgetless (no heartbeat yet): the
		// pair already proved recovery, so nothing may block admission.
		r.Disconnect(sess1)
		p2 := attestSchedulerProvider(t, r, sess2, model, serial, 100)
		p2.mu.Lock()
		p2.BackendCapacity = nil
		p2.mu.Unlock()
		if r.BudgetClampActive(p2.ID, model) {
			t.Fatal("released clamp revived on the reconnected session's budgetless pre-heartbeat window")
		}
		if sel, _ := reserveOnce(r, model, "post-release-reconnect"); sel == nil {
			t.Fatal("reconnect after a full release must be admittable")
		}
	}

	t.Run("released by the heartbeat sweep (accept then heartbeat, no further traffic)", func(t *testing.T) {
		run(t, "SER-REL-HB", "rel-hb-1", "rel-hb-2", func(r *Registry, providerID string) {
			r.RecordCapacityAccept(providerID, model)
			time.Sleep(2 * time.Millisecond)
			sendBudgetHeartbeat(r, providerID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
		})
	})
	t.Run("released by the accept-path drop (heartbeat then accept)", func(t *testing.T) {
		run(t, "SER-REL-AC", "rel-ac-1", "rel-ac-2", func(r *Registry, providerID string) {
			time.Sleep(2 * time.Millisecond)
			sendBudgetHeartbeat(r, providerID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
			r.RecordCapacityAccept(providerID, model)
		})
	})
}

// The heartbeat release sweep must evaluate the heartbeat's OWN snapshot, not
// re-read r.providers: a Disconnect racing in between the heartbeat stamping
// the provider and the sweep running would otherwise find no provider, skip
// the delete, and let the released entry re-block the identity's next
// reconnect (Codex round-3 review follow-up). Simulated deterministically by
// disconnecting BEFORE the sweep runs with the heartbeat's values — the
// 2-minute disconnectedStableIDs cache keeps the session resolvable, exactly
// as in the production race.
func TestBudgetClampHeartbeatReleaseSurvivesDisconnectRace(t *testing.T) {
	r := New(testLogger())
	const model, serial = "gemma-4-26b-qat-4bit", "SER-REL-RACE"

	p1 := attestSchedulerProvider(t, r, "rel-race-1", model, serial, 100)
	p1.mu.Lock()
	p1.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = grayBoxBudgetUsed
	p1.BackendCapacity.Slots[0].ActiveTokenBudgetMax = grayBoxBudgetMax
	p1.mu.Unlock()

	r.RecordCapacityReject(p1.ID, model)
	r.RecordCapacityAccept(p1.ID, model)
	time.Sleep(2 * time.Millisecond)

	// The heartbeat that proves release arrives... and the provider disconnects
	// before the sweep runs. Replay the sweep exactly as Heartbeat would have
	// called it, with the heartbeat's own stamped time and report.
	heartbeatAt := time.Now()
	capacity := &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			ActiveTokenBudgetUsed: grayBoxBudgetUsed,
			ActiveTokenBudgetMax:  grayBoxBudgetMax,
		}},
	}
	r.Disconnect("rel-race-1")
	r.releaseBudgetClampsOnHeartbeat("rel-race-1", heartbeatAt, capacity)

	r.mu.RLock()
	_, lingering := r.budgetClamps[capacityRejectKey{ProviderID: "serial:" + serial, ModelID: model}]
	r.mu.RUnlock()
	if lingering {
		t.Fatal("release proof voided by the disconnect race — the sweep must evaluate the heartbeat's own snapshot")
	}

	// The reconnect (budgetless, pre-heartbeat) must not be blocked.
	p2 := attestSchedulerProvider(t, r, "rel-race-2", model, serial, 100)
	p2.mu.Lock()
	p2.BackendCapacity = nil
	p2.mu.Unlock()
	if r.BudgetClampActive(p2.ID, model) {
		t.Fatal("released clamp revived on reconnect after the disconnect race")
	}
}

// Inactive clamp entries (released / TTL-expired / budgetless-armed) must be
// DELETED, not merely read as inactive: RecordCapacityAccept's healthy-pair
// fast path keys on map presence, so a lingering entry would pull every later
// accept for the pair onto the r.mu write lock indefinitely (Codex review of
// #523, round 3). An ACTIVE clamp's entry must survive its accepts until the
// full release proof.
func TestBudgetClampInactiveEntriesAreDeleted(t *testing.T) {
	const model = "gemma-4-26b-qat-4bit"

	clampEntryExists := func(r *Registry, providerID string) bool {
		r.mu.RLock()
		defer r.mu.RUnlock()
		_, ok := r.budgetClamps[capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: model}]
		return ok
	}

	t.Run("TTL-expired entry dropped on the next accept", func(t *testing.T) {
		r := New(testLogger())
		p := makeTokenBudgetProvider(t, r, "ttl-drop", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)
		r.RecordCapacityReject(p.ID, model)
		ageBudgetClamp(r, p.ID, model, defaultBudgetClampTTL+time.Second)
		r.RecordCapacityAccept(p.ID, model)
		if clampEntryExists(r, p.ID) {
			t.Fatal("TTL-expired clamp entry must be deleted by the accept path")
		}
	})

	t.Run("budgetless-armed entry dropped on the next accept", func(t *testing.T) {
		r := New(testLogger())
		p := makeSchedulerProvider(t, r, "budgetless-drop", model, 100) // no token budget
		r.RecordCapacityRejectLifecycle(p.ID, model)
		if !clampEntryExists(r, p.ID) {
			t.Fatal("setup: lifecycle reject must have armed a (never-gating) entry")
		}
		r.RecordCapacityAccept(p.ID, model)
		if clampEntryExists(r, p.ID) {
			t.Fatal("budgetless-armed (never-gating) clamp entry must be deleted by the accept path")
		}
	})

	t.Run("active entry survives accepts until the full release proof", func(t *testing.T) {
		r := New(testLogger())
		p := makeTokenBudgetProvider(t, r, "active-keep", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)
		r.RecordCapacityReject(p.ID, model)
		// Accept with a stale (pre-clamp) heartbeat: release unproven — the
		// entry must stay (and keep gating).
		r.RecordCapacityAccept(p.ID, model)
		if !clampEntryExists(r, p.ID) {
			t.Fatal("an unreleased clamp entry must survive the accept (release still needs the fresh heartbeat)")
		}
		if !r.BudgetClampActive(p.ID, model) {
			t.Fatal("unreleased clamp must still gate")
		}
		// The fresh-headroom heartbeat completes the proof: the sweep deletes.
		time.Sleep(2 * time.Millisecond)
		sendBudgetHeartbeat(r, p.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
		if clampEntryExists(r, p.ID) {
			t.Fatal("fully released clamp entry must be deleted so the pair returns to the accept fast path")
		}
	})
}

// setAttestationAndBind completes a valid attestation for an already-registered
// provider through the real SetAttestationResult path (which performs the
// fault-state migration under test).
func setAttestationAndBind(t *testing.T, r *Registry, p *Provider, serial string) {
	t.Helper()
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: serial})
	if got := faultKeyOf(r, p.ID); got != "serial:"+serial {
		t.Fatalf("bind failed: fault key = %q, want serial:%s", got, serial)
	}
}

// THE prod regression (Jul 6 gray-box scenario): a provider whose heartbeat
// advertises a huge budget but whose dispatches capacity-503 ~40% of the time
// with interleaved accepts. Every pre-fix breaker is blind (each accept resets
// the zero-interleaved-accepts discriminators), so the faster gray box keeps
// winning selection outright. With the fix, its capacity-503 rate sinks it in
// cost ranking and its selection share drops materially; the healthy peers
// absorb the traffic. The kill switches restore the old (blind) behavior —
// asserted here as the without-fix baseline.
func TestGrayBoxSelectionShareDropsWithFix(t *testing.T) {
	const model = "gemma-4-26b-qat-4bit"
	const iterations = 60
	const measureTail = 25 // selection share measured over the last N iterations

	// runScenario drives the production selection loop against one gray box
	// (fast: observed 200 TPS, huge advertised budget) and three identical
	// healthy peers (slower: 60 TPS). Gray outcomes follow a fixed 40%
	// capacity-503 pattern (R A A R A) with interleaved accepts — each reject
	// is paired with an accept from a concurrently in-flight request (the prod
	// gray box served ~60%), and both boxes heartbeat every iteration (the
	// prod 15-30s cadence, compressed), so the CLAMP keeps releasing and the
	// sustained defense under test is the rate penalty.
	runScenario := func(t *testing.T) (grayTailShare float64, sawPenalty bool, maxRate float64) {
		t.Helper()
		r := New(testLogger())
		// The gray box heartbeats IDLE-LOOKING (used=0 of 5.2M — maximally
		// stale-optimistic, the prod signature) and is the fastest box, so the
		// cost scheduler prefers it outright until something teaches it better.
		gray := makeTokenBudgetProvider(t, r, "gray-box", model, 200, 0, grayBoxBudgetMax, 200)
		healthy := make([]*Provider, 3)
		for i := range healthy {
			healthy[i] = makeTokenBudgetProvider(t, r, fmt.Sprintf("healthy-%d", i), model, 60, 0, 200_000, 60)
		}

		pattern := []bool{true, false, false, true, false} // true = capacity-503 (40%)
		grayOutcome := 0
		grayTailSelections := 0
		for i := 0; i < iterations; i++ {
			// Heartbeats: everyone re-advertises an optimistic budget (the
			// gray box's is stale-optimistic by definition).
			sendBudgetHeartbeat(r, gray.ID, model, 0, grayBoxBudgetMax)
			for _, h := range healthy {
				sendBudgetHeartbeat(r, h.ID, model, 0, 200_000)
			}

			rid := fmt.Sprintf("req-%d", i)
			sel, decision := r.ReserveProviderEx(model, &PendingRequest{
				RequestID:             rid,
				Model:                 model,
				EstimatedPromptTokens: 200,
				RequestedMaxTokens:    512,
			})
			if sel == nil {
				t.Fatalf("iteration %d: no provider selectable", i)
			}
			sel.RemovePending(rid)
			r.SetProviderIdle(sel.ID)

			if sel.ID == gray.ID {
				if i >= iterations-measureTail {
					grayTailSelections++
				}
				if decision.CapacityRateMs > 0 {
					sawPenalty = true
				}
				if decision.CapacityRejectRate > maxRate {
					maxRate = decision.CapacityRejectRate
				}
				if pattern[grayOutcome%len(pattern)] {
					// Capacity-503 — and an interleaved accept from an
					// in-flight request committing content (the gray-box
					// signature that blinds every reset-on-accept breaker).
					r.RecordCapacityReject(gray.ID, model)
					r.RecordCapacityAccept(gray.ID, model)
				} else {
					r.RecordCapacityAccept(gray.ID, model)
				}
				grayOutcome++
			} else {
				r.RecordCapacityAccept(sel.ID, model)
			}
		}
		return float64(grayTailSelections) / float64(measureTail), sawPenalty, maxRate
	}

	t.Run("without fix (kill switches) the gray box stays preferred", func(t *testing.T) {
		t.Setenv(envBudgetClamp, "false")
		t.Setenv(envCapacityRatePenaltyMs, "0")
		share, sawPenalty, _ := runScenario(t)
		if sawPenalty {
			t.Fatal("kill switch off: no penalty may be applied")
		}
		if share < 0.9 {
			t.Fatalf("without the fix the faster gray box must keep winning (share = %.2f, want >= 0.9) — if this fails the baseline no longer reproduces the prod blindness", share)
		}
	})

	t.Run("with fix the gray box loses its monopoly", func(t *testing.T) {
		share, sawPenalty, maxRate := runScenario(t)
		if !sawPenalty {
			t.Fatal("the capacity-503 rate penalty never appeared in a winning decision")
		}
		if maxRate <= capacityRateThreshold {
			t.Fatalf("measured reject rate %.2f never exceeded the threshold %.2f", maxRate, capacityRateThreshold)
		}
		if share > 0.6 {
			t.Fatalf("gray box selection share = %.2f over the last %d iterations, want <= 0.6 (healthy peers must absorb traffic)", share, measureTail)
		}
	})
}

// A clamp armed while the pair reported NO budget (a cold "model not loaded"
// miss, or a first dispatch before the first capacity heartbeat) must NOT
// retroactively gate the pair once a later heartbeat starts reporting a
// budget: the reject was budgetless, so it is not the stale-budget lie the
// clamp exists to override, and — because the clamp would block dispatch — no
// accept could ever land to prove release, stranding the warmed-up pair until
// TTL (Codex review of #523). Contrast TestBudgetClampSurvivesReconnect, where
// the clamp armed while budget-reporting and MUST hold.
func TestBudgetClampArmedBudgetlessDoesNotGateAfterBudgetAppears(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-qat-4bit"
	// The slot reports NO token budget (cold / pre-load): the reject arms the
	// clamp with budgetReported=false.
	p := makeSchedulerProvider(t, r, "cold-box", model, 100)

	r.RecordCapacityReject(p.ID, model)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("a budgetless capacity reject must not gate the pair (legacy/cold exemption)")
	}

	// The model finishes loading; the first budget heartbeat arrives (strictly
	// after the clamp, with meaningful headroom). Pre-fix, the budgeted release
	// branch found acceptedSince=false and re-activated the clamp until TTL.
	time.Sleep(2 * time.Millisecond)
	sendBudgetHeartbeat(r, p.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("a clamp armed while budgetless must not activate once a budget heartbeat arrives — no dispatch could produce the accept proof, so it would strand until TTL")
	}
	if sel, _ := reserveOnce(r, model, "warmed-up"); sel == nil {
		t.Fatal("warmed-up pair must be admittable — a budgetless-armed clamp must never gate it")
	}

	// But a GENUINE reject now (while budget-reporting) DOES arm a gating clamp:
	// the sticky-or upgrades budgetReported, so this is real stale-budget
	// dishonesty, not warm-up.
	r.RecordCapacityReject(p.ID, model)
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("a capacity reject while the pair reports a budget must gate (real gray-box signal)")
	}
}

// A clamped identity that reconnects has NO BackendCapacity until its first
// heartbeat. The clamp must keep holding through that budgetless window — the
// snapshot falling back to the legacy memory-admission path would shed the
// clamp at the exact moment the stable fault key exists to prevent it (Codex
// review of #523). Release then works normally once the first post-clamp
// budget heartbeat + an accept land.
func TestBudgetClampHoldsAcrossReconnectBeforeFirstHeartbeat(t *testing.T) {
	r := New(testLogger())
	const model, serial = "gemma-4-26b-qat-4bit", "SER-CLAMP-HB"

	p1 := attestSchedulerProvider(t, r, "clamp-hb-sess-1", model, serial, 100)
	p1.mu.Lock()
	p1.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = grayBoxBudgetUsed
	p1.BackendCapacity.Slots[0].ActiveTokenBudgetMax = grayBoxBudgetMax
	p1.mu.Unlock()

	r.RecordCapacityReject(p1.ID, model)
	if !r.BudgetClampActive(p1.ID, model) {
		t.Fatal("setup: clamp must be active")
	}
	r.Disconnect("clamp-hb-sess-1")

	// Reconnect: registration completes, attestation binds the same stable
	// identity, but the first heartbeat has NOT arrived — BackendCapacity nil.
	p2 := attestSchedulerProvider(t, r, "clamp-hb-sess-2", model, serial, 100)
	p2.mu.Lock()
	p2.BackendCapacity = nil
	p2.mu.Unlock()

	if !r.BudgetClampActive(p2.ID, model) {
		t.Fatal("clamp must hold through the reconnected session's budgetless pre-heartbeat window")
	}
	if sel, _ := reserveOnce(r, model, "reconnect-pre-heartbeat"); sel != nil {
		t.Fatal("budgetless reconnect window shed the clamp — admission fell back to the legacy memory path")
	}

	// Release proof through the new session: accept + first post-clamp budget
	// heartbeat with meaningful headroom.
	r.RecordCapacityAccept(p2.ID, model)
	time.Sleep(2 * time.Millisecond)
	sendBudgetHeartbeat(r, p2.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
	if r.BudgetClampActive(p2.ID, model) {
		t.Fatal("release proof through the reconnected session must lift the clamp")
	}
	if sel, _ := reserveOnce(r, model, "post-release"); sel == nil {
		t.Fatal("released pair must admit again")
	}
}
