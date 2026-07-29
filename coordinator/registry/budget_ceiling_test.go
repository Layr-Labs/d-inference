package registry

import (
	"testing"
	"time"
)

// Tests for the learned effective token-budget ceiling (budget_ceiling.go).
//
// Regression suite for the v0.8.0 paged rollout: a paged slot advertises
// poolBytes / kvBytesPerToken, where kvBytesPerToken is the MARGINAL
// long-context rate, while the pool's real charge is AFFINE (a fixed
// sliding-window ring per in-flight sequence plus the marginal per-token
// cost). The advertised budget therefore over-states concurrent capacity by
// ~1.6× at batch 8, which makes the one-shot clamp's release condition — raw
// max − used − queued ≥ 1024 — true on the very next heartbeat, forever. The
// clamp becomes a treadmill: bounce one request, release, bounce again.

// Paged gemma-4 shape on a 96 GiB box: a 6 GiB pool at the slot's reported
// 20,480 B/token marginal rate advertises ~314k tokens. Six ~20k-token
// sequences (120k tokens of reported commitment) already exhaust it, because
// each also costs a ~303 MiB ring the wire budget does not price.
const (
	pagedAdvertisedTokens = int64(314_572) // 6 GiB / 20,480 B per token
	pagedCommittedTokens  = int64(120_000) // six in-flight ~20k sequences
	pagedRequestPrompt    = 20_000
	pagedRequestMaxTokens = 256
)

// pagedRequestTokens is what the seventh request asks for, in the same units
// the admission gate speaks.
const pagedRequestTokens = int64(pagedRequestPrompt + pagedRequestMaxTokens)

// reserveSized runs the production reservation path once for a request of the
// paged shape above and releases the reservation, returning the selected
// provider (nil = no route).
func reserveSized(r *Registry, model, requestID string) *Provider {
	p, _ := r.ReserveProviderEx(model, &PendingRequest{
		RequestID:             requestID,
		Model:                 model,
		EstimatedPromptTokens: pagedRequestPrompt,
		RequestedMaxTokens:    pagedRequestMaxTokens,
	})
	if p != nil {
		p.RemovePending(requestID)
		r.SetProviderIdle(p.ID)
	}
	return p
}

// proveClampRelease delivers the clamp's two release conditions — an accept
// and a strictly-fresher heartbeat with meaningful headroom — restating the
// SAME inflated budget the provider reported before the reject. That is the
// treadmill: the heartbeat is not stale, it is honestly reporting a number
// whose model of the pool is wrong, so it always satisfies release.
func proveClampRelease(t *testing.T, r *Registry, providerID, model string) {
	t.Helper()
	r.RecordCapacityAccept(providerID, model)
	time.Sleep(2 * time.Millisecond)
	sendBudgetHeartbeat(r, providerID, model, pagedCommittedTokens, pagedAdvertisedTokens)
	if r.BudgetClampActive(providerID, model) {
		t.Fatal("setup: the one-shot clamp must release here — that is the treadmill this test is about")
	}
}

// ageBudgetCeiling rewinds the pair's ceiling latch by d (simulating TTL
// passage without sleeping), keyed by the pair's CURRENT fault key.
func ageBudgetCeiling(r *Registry, providerID, model string, d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: model}
	if e, ok := r.budgetCeilings[key]; ok {
		e.latchedAt = e.latchedAt.Add(-d)
	}
}

// THE TREADMILL. A pair whose advertised budget is structurally inflated
// satisfies the clamp's release condition on the very next heartbeat, so
// clamp-only behaviour re-selects it at the exact commitment that just failed —
// one bounced request per heartbeat, indefinitely. The learned ceiling must
// outlive the clamp and deselect the pair BEFORE dispatch, and must widen back
// once the pair proves (through sustained accepts) that more fits.
func TestBudgetCeilingBreaksTheClampTreadmill(t *testing.T) {
	const model = "gemma-4-26b-qat-4bit"
	r := New(testLogger())
	p := makeTokenBudgetProvider(t, r, "paged-box", model, 100, pagedCommittedTokens, pagedAdvertisedTokens, 100)
	sendBudgetHeartbeat(r, p.ID, model, pagedCommittedTokens, pagedAdvertisedTokens)

	if sel := reserveSized(r, model, "seventh"); sel == nil {
		t.Fatal("setup: the request must fit the ADVERTISED budget — that is why it is dispatched and then rejected")
	}

	// The provider rejects it: the pool is affine and physically full.
	r.RecordCapacityRejectSized(p.ID, model, int(pagedRequestTokens))

	wantCeiling := pagedCommittedTokens + pagedRequestTokens - budgetCeilingMarginTokens
	gotCeiling, latched := r.BudgetCeiling(p.ID, model)
	if !latched || gotCeiling != wantCeiling {
		t.Fatalf("learned ceiling = (%d, latched=%v), want (%d, true) — min(advertised, used+queued+request-margin)",
			gotCeiling, latched, wantCeiling)
	}

	// The clamp releases on the next heartbeat, exactly as it does in prod.
	proveClampRelease(t, r, p.ID, model)

	// THE ASSERTION. Same commitment, same request, released clamp: the pair
	// must NOT be re-selected. The request falls to the queue-before-shed
	// spill instead of being dispatched into a guaranteed rejection.
	if sel := reserveSized(r, model, "eighth"); sel != nil {
		t.Fatalf("pair %s re-selected at the same commitment after the clamp released — the treadmill is still running", sel.ID)
	}

	// Sustained accepts are the only provider-side proof that more fits than
	// the reject taught us. One widen step must restore selection.
	for i := 1; i < budgetCeilingWidenAccepts; i++ {
		r.RecordCapacityAccept(p.ID, model)
	}
	widened, stillLatched := r.BudgetCeiling(p.ID, model)
	if !stillLatched || widened <= wantCeiling {
		t.Fatalf("ceiling after %d accepts = (%d, latched=%v), want a value above %d",
			budgetCeilingWidenAccepts, widened, stillLatched, wantCeiling)
	}
	if widened < pagedCommittedTokens+pagedRequestTokens {
		t.Fatalf("widen step too small: ceiling %d still below the %d commitment it must re-admit",
			widened, pagedCommittedTokens+pagedRequestTokens)
	}
	if sel := reserveSized(r, model, "ninth"); sel == nil {
		t.Fatal("pair must be selectable again once accepts widened the ceiling past the commitment")
	}
}

// The kill switch restores exactly the pre-change behaviour: clamp releases,
// pair is re-selected at the failing commitment. This is what the test above
// is a fix for, pinned so the two cannot silently converge.
func TestBudgetCeilingKillSwitchRestoresTreadmill(t *testing.T) {
	const model = "gemma-4-26b-qat-4bit"
	t.Setenv(envBudgetCeiling, "false")
	r := New(testLogger())
	p := makeTokenBudgetProvider(t, r, "paged-box", model, 100, pagedCommittedTokens, pagedAdvertisedTokens, 100)
	sendBudgetHeartbeat(r, p.ID, model, pagedCommittedTokens, pagedAdvertisedTokens)

	r.RecordCapacityRejectSized(p.ID, model, int(pagedRequestTokens))
	if _, latched := r.BudgetCeiling(p.ID, model); latched {
		t.Fatal("kill switch off must learn nothing")
	}
	proveClampRelease(t, r, p.ID, model)
	if sel := reserveSized(r, model, "again"); sel == nil {
		t.Fatal("with the ceiling disabled the pair must be re-selected — the documented pre-change behaviour")
	}
}

// A learned ceiling can only ever TIGHTEN admission relative to the advertised
// budget. It is applied as min(advertised, learned) at every read, so no state
// of this machine can admit a request the raw heartbeat would have refused.
func TestBudgetCeilingNeverExceedsAdvertised(t *testing.T) {
	const model = "m"
	r := New(testLogger())
	key := capacityRejectKey{ProviderID: "box", ModelID: model}
	now := time.Now()

	// A ceiling learned against a large advertised budget must not survive as
	// an over-statement once the pair advertises much less (co-tenancy, a
	// smaller re-slice).
	r.recordBudgetCeilingLocked(key, 200_000, 0, 1_000_000, now)
	if got := r.budgetCeilingLocked("box", model, 50_000, now); got != 50_000 {
		t.Fatalf("effective max = %d, want the smaller advertised 50000 — the ceiling is a cap, not a substitute", got)
	}
	if got := r.budgetCeilingLocked("box", model, 1_000_000, now); got != 200_000-budgetCeilingMarginTokens {
		t.Fatalf("effective max = %d, want the learned %d", got, 200_000-budgetCeilingMarginTokens)
	}
}

// Boundary behaviour of the latch itself.
func TestBudgetCeilingLatchBoundaries(t *testing.T) {
	const model = "m"
	key := capacityRejectKey{ProviderID: "box", ModelID: model}

	t.Run("no latch when the implied ceiling is not tighter than advertised", func(t *testing.T) {
		r := New(testLogger())
		now := time.Now()
		// The box rejected AT its advertised budget: the advertised number was
		// already binding, so there is nothing to learn (ordinary fullness,
		// owned by the queue path).
		r.recordBudgetCeilingLocked(key, 100_000+budgetCeilingMarginTokens, 100_000, 100_000, now)
		if _, latched := r.BudgetCeiling("box", model); latched {
			t.Fatal("a reject at or above the advertised budget must teach nothing")
		}
	})

	t.Run("floored at the provider minimum serving budget", func(t *testing.T) {
		r := New(testLogger())
		now := time.Now()
		// A reject at a small commitment would imply a ceiling below the
		// provider's own minimum serving budget; a zero/negative ceiling is a
		// permanent clamp wearing a different name. The floor still binds
		// here, because the failing commitment is above it.
		r.recordBudgetCeilingLocked(key, budgetCeilingFloorTokens+500, 0, 100_000, now)
		got, latched := r.BudgetCeiling("box", model)
		if !latched || got != budgetCeilingFloorTokens {
			t.Fatalf("ceiling = (%d, %v), want (%d, true)", got, latched, budgetCeilingFloorTokens)
		}
	})

	t.Run("no entry when the floor would gate nothing", func(t *testing.T) {
		r := New(testLogger())
		now := time.Now()
		// The whole failing commitment fits under one provider-minimum budget,
		// so the floored ceiling lands at or above it: the identical request at
		// the identical commitment would be re-admitted. Such an entry gates
		// nothing while still burning a TTL and the accept bookkeeping, so it
		// must not be created at all.
		r.recordBudgetCeilingLocked(key, budgetCeilingFloorTokens-1, 0, 100_000, now)
		if _, latched := r.BudgetCeiling("box", model); latched {
			t.Fatal("a ceiling that cannot gate the request that produced it must not be latched")
		}
	})

	t.Run("never below what the pair reports it already holds", func(t *testing.T) {
		r := New(testLogger())
		now := time.Now()
		// A sub-margin request rejected at 80k committed: the margin alone
		// would push the ceiling under the live commitment, which the
		// provider's own report contradicts and which would deselect the pair
		// for every request size.
		r.recordBudgetCeilingLocked(key, 80_000+100, 80_000, 1_000_000, now)
		got, latched := r.BudgetCeiling("box", model)
		if !latched || got != 80_000 {
			t.Fatalf("ceiling = (%d, %v), want (80000, true)", got, latched)
		}
		// It still refuses the request that failed: any positive demand on
		// top of a ceiling equal to the commitment does not fit.
		snap := routingSnapshot{
			activeTokenBudgetMax:  1_000_000,
			activeTokenBudgetUsed: 80_000,
			learnedTokenBudgetMax: got,
		}
		if freeMemoryAdmits(snap, 100, 0) {
			t.Fatal("a ceiling equal to the commitment must still refuse the request that failed")
		}
	})

	t.Run("rejects ratchet down, never up, and do not refresh the TTL", func(t *testing.T) {
		r := New(testLogger())
		now := time.Now()
		r.recordBudgetCeilingLocked(key, 50_000, 0, 1_000_000, now)
		tight, _ := r.BudgetCeiling("box", model)
		// A later reject at a HIGHER commitment (the box was busier) must not
		// undo what the tighter one taught. Only accepts widen.
		later := now.Add(time.Minute)
		r.recordBudgetCeilingLocked(key, 900_000, 800_000, 1_000_000, later)
		got, _ := r.BudgetCeiling("box", model)
		if got != tight {
			t.Fatalf("ceiling = %d after a looser reject, want the ratcheted %d", got, tight)
		}
		// …and it must not have moved the TTL anchor either. A derating window
		// extended by evidence that did not produce the ceiling is how a
		// bounded fail-open becomes an unbounded one.
		r.mu.RLock()
		anchor := r.budgetCeilings[key].latchedAt
		r.mu.RUnlock()
		if !anchor.Equal(now) {
			t.Fatalf("TTL anchor = %v, want the original latch %v — a non-tightening reject must not refresh it", anchor, now)
		}
	})

	t.Run("unlearnable inputs are no-ops", func(t *testing.T) {
		r := New(testLogger())
		now := time.Now()
		r.recordBudgetCeilingLocked(key, 0, 0, 1_000_000, now)  // no request size
		r.recordBudgetCeilingLocked(key, 50_000, 0, 0, now)     // budgetless pair
		r.recordBudgetCeilingLocked(key, -1, 0, 1_000_000, now) // nonsense commitment
		if _, latched := r.BudgetCeiling("box", model); latched {
			t.Fatal("a ceiling cannot be learned without both a commitment and an advertised budget")
		}
	})

	t.Run("TTL fails open", func(t *testing.T) {
		r := New(testLogger())
		p := makeTokenBudgetProvider(t, r, "box", model, 100, 0, 1_000_000, 100)
		r.RecordCapacityRejectSized(p.ID, model, 50_000)
		if _, latched := r.BudgetCeiling(p.ID, model); !latched {
			t.Fatal("setup: ceiling must latch")
		}
		ageBudgetCeiling(r, p.ID, model, r.budgetCeilingCfg.TTL+time.Second)
		if _, latched := r.BudgetCeiling(p.ID, model); latched {
			t.Fatal("an expired ceiling must fail open — widening cannot rescue a ceiling that blocks every request size")
		}
		r.mu.RLock()
		effective := r.budgetCeilingLocked(p.ID, model, 1_000_000, time.Now())
		r.mu.RUnlock()
		if effective != 1_000_000 {
			t.Fatalf("expired ceiling still gating: effective max = %d, want the advertised 1000000", effective)
		}
	})
}

// The size-less entry point records a strike and a clamp but teaches nothing:
// without the request size the commitment that failed is unknown, and a
// ceiling learned from used+queued alone would be tighter than the evidence.
func TestBudgetCeilingRequiresASizedReject(t *testing.T) {
	const model = "m"
	r := New(testLogger())
	p := makeTokenBudgetProvider(t, r, "box", model, 100, 100_000, 1_000_000, 100)

	r.RecordCapacityReject(p.ID, model)
	if _, latched := r.BudgetCeiling(p.ID, model); latched {
		t.Fatal("an unsized reject must not latch a ceiling")
	}
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("an unsized reject must still arm the one-shot clamp")
	}
}

// Rejects that indict the REQUEST (an oversized prompt, a cold "not loaded"
// miss, an admission timeout) say nothing about the pair's budget arithmetic
// and must arm neither gray-box tracker — the same armClamp gate the clamp
// already honours.
func TestBudgetCeilingNotArmedByNonProviderRejects(t *testing.T) {
	const model = "m"
	for name, record := range map[string]func(*Registry, string){
		"lifecycle":     func(r *Registry, id string) { r.RecordCapacityRejectLifecycle(id, model) },
		"request_shape": func(r *Registry, id string) { r.RecordCapacityRejectRequestShape(id, model) },
		"busy":          func(r *Registry, id string) { r.RecordCapacityRejectBusy(id, model) },
	} {
		t.Run(name, func(t *testing.T) {
			r := New(testLogger())
			p := makeTokenBudgetProvider(t, r, "box", model, 100, 100_000, 1_000_000, 100)
			record(r, p.ID)
			if _, latched := r.BudgetCeiling(p.ID, model); latched {
				t.Fatalf("%s reject must not latch a budget ceiling", name)
			}
		})
	}
}

// A ceiling that catches up with the advertised budget is DELETED, not left
// pinned at parity: the pair is healed and belongs back on pure heartbeat
// semantics, and a lingering entry keeps pulling every later accept onto the
// registry write lock.
func TestBudgetCeilingDeletedOnceHealed(t *testing.T) {
	const model = "m"
	r := New(testLogger())
	p := makeTokenBudgetProvider(t, r, "box", model, 100, 0, 8_000, 100)
	sendBudgetHeartbeat(r, p.ID, model, 0, 8_000)

	r.RecordCapacityRejectSized(p.ID, model, 5_000)
	if _, latched := r.BudgetCeiling(p.ID, model); !latched {
		t.Fatal("setup: ceiling must latch below the 8000 advertised budget")
	}
	// Widen repeatedly; +25% per budgetCeilingWidenAccepts accepts reaches
	// 8000 from 3976 in four steps.
	for i := 0; i < 8*budgetCeilingWidenAccepts; i++ {
		r.RecordCapacityAccept(p.ID, model)
		if _, latched := r.BudgetCeiling(p.ID, model); !latched {
			return // healed and deleted
		}
	}
	t.Fatal("ceiling never healed back to the advertised budget under sustained accepts")
}

// An identity rebind (session id → SE key → serial) must carry the TIGHTER
// ceiling, not the fresher one. A rebind is not evidence about capacity, and
// taking the later entry would let it widen a ceiling only accepts may widen.
// Expiry decides FIRST though: an expired entry has no evidentiary standing on
// either side, and comparing tokens blind would let an expired-but-tighter
// source silently destroy a live destination (the survivor would carry the
// source's stale anchor, so it would read as expired and gate nothing).
func TestBudgetCeilingMigratesTighterOnIdentityRebind(t *testing.T) {
	const model = "m"
	oldKey := capacityRejectKey{ProviderID: "old", ModelID: model}
	newKey := capacityRejectKey{ProviderID: "new", ModelID: model}

	for name, tc := range map[string]struct {
		source, dest *budgetCeilingEntry // nil = absent
		wantTokens   int64               // 0 = nothing survives
	}{
		"tighter live source wins": {
			source: &budgetCeilingEntry{tokens: 20_000}, dest: &budgetCeilingEntry{tokens: 90_000},
			wantTokens: 20_000,
		},
		"tighter live destination is kept": {
			source: &budgetCeilingEntry{tokens: 90_000}, dest: &budgetCeilingEntry{tokens: 20_000},
			wantTokens: 20_000,
		},
		"expired source must not displace a live destination": {
			source: &budgetCeilingEntry{tokens: 20_000, latchedAt: time.Now().Add(-time.Hour)},
			dest:   &budgetCeilingEntry{tokens: 90_000},
			// The tighter number is expired evidence: the live 90k stands.
			wantTokens: 90_000,
		},
		"expired source alone is dropped": {
			source:     &budgetCeilingEntry{tokens: 20_000, latchedAt: time.Now().Add(-time.Hour)},
			wantTokens: 0,
		},
		"live source moves onto an empty key": {
			source: &budgetCeilingEntry{tokens: 20_000}, wantTokens: 20_000,
		},
		"live source replaces an expired destination": {
			source: &budgetCeilingEntry{tokens: 90_000},
			dest:   &budgetCeilingEntry{tokens: 20_000, latchedAt: time.Now().Add(-time.Hour)},
			// Looser, but it is the only entry with standing.
			wantTokens: 90_000,
		},
	} {
		t.Run(name, func(t *testing.T) {
			r := New(testLogger())
			now := time.Now()
			r.mu.Lock()
			defer r.mu.Unlock()
			for key, e := range map[capacityRejectKey]*budgetCeilingEntry{oldKey: tc.source, newKey: tc.dest} {
				if e == nil {
					continue
				}
				if e.latchedAt.IsZero() {
					e.latchedAt = now
				}
				r.budgetCeilings[key] = e
			}
			r.migrateFaultStateLocked("old", "new")

			if _, ok := r.budgetCeilings[oldKey]; ok {
				t.Fatal("old-key entry must always be removed by the migration")
			}
			got, ok := r.budgetCeilings[newKey]
			if tc.wantTokens == 0 {
				if ok {
					t.Fatalf("ceiling %d survived, want nothing to migrate", got.tokens)
				}
				return
			}
			if !ok || got.tokens != tc.wantTokens {
				t.Fatalf("migrated ceiling = %v, want %d", got, tc.wantTokens)
			}
			// Whatever survived must still be able to gate: an entry whose
			// anchor is already expired is indistinguishable from no entry.
			if !now.Before(got.latchedAt.Add(r.budgetCeilingCfg.TTL)) {
				t.Fatal("the surviving entry carries an expired anchor — it gates nothing")
			}
		})
	}
}

// THE STARVATION PATH, pinned. A ceiling low enough to deselect the pair for
// EVERY request size the model receives produces no accepts, so widening is
// unreachable and the TTL is the only recovery. That is the design's most
// consequential failure mode: this test states it explicitly so nobody
// discovers it in production, and pins the TTL as the bound on it.
func TestBudgetCeilingStarvationRecoversOnlyOnTTL(t *testing.T) {
	const model = "m"
	r := New(testLogger())
	// A model whose traffic is uniformly long: every request is ~20k tokens,
	// so nothing fits under a ceiling learned near that size.
	p := makeTokenBudgetProvider(t, r, "box", model, 100, 0, pagedAdvertisedTokens, 100)
	sendBudgetHeartbeat(r, p.ID, model, 0, pagedAdvertisedTokens)

	r.RecordCapacityRejectSized(p.ID, model, int(pagedRequestTokens))
	learned, latched := r.BudgetCeiling(p.ID, model)
	if !latched || learned >= pagedRequestTokens {
		t.Fatalf("setup: ceiling = (%d, %v), want a latch below the %d request size",
			learned, latched, pagedRequestTokens)
	}
	// Release the one-shot clamp so the CEILING is unambiguously what gates
	// from here. The release accept is the straggler that was already in
	// flight when the latch landed — one accept, three short of a widen step,
	// and a dark pair cannot earn the other three.
	r.RecordCapacityAccept(p.ID, model)
	time.Sleep(2 * time.Millisecond)
	sendBudgetHeartbeat(r, p.ID, model, 0, pagedAdvertisedTokens)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("setup: the one-shot clamp must release, or it is the clamp under test and not the ceiling")
	}

	// Dark: the box is idle, nothing is committed, and it is STILL deselected —
	// draining cannot help, because the ceiling is below one request.
	if sel := reserveSized(r, model, "starved"); sel != nil {
		t.Fatal("setup: a ceiling below one request size must deselect an idle pair")
	}
	// No dispatch ⇒ no accept ⇒ no widen. Even the accepts the widen path
	// wants cannot be manufactured, which is the point.
	if _, stillLatched := r.BudgetCeiling(p.ID, model); !stillLatched {
		t.Fatal("nothing but the TTL may retire a starved ceiling")
	}

	ageBudgetCeiling(r, p.ID, model, r.budgetCeilingCfg.TTL+time.Second)
	if _, stillLatched := r.BudgetCeiling(p.ID, model); stillLatched {
		t.Fatal("the TTL is the fail-open bound on starvation; it must expire the ceiling")
	}
	if sel := reserveSized(r, model, "recovered"); sel == nil {
		t.Fatal("pair must be selectable again once the ceiling expires")
	}
}

// THE BURST. The heartbeat's committed figure lags by up to one heartbeat
// interval, so a burst that the coordinator itself dispatched is invisible in
// it. Learning off the heartbeat alone would read used≈0 mid-burst and latch a
// ceiling an order of magnitude tighter than the evidence supports; the
// commitment must therefore be max(heartbeat, coordinator pending), which is
// the same quantity freeMemoryAdmits charges as coordinatorExtra.
func TestBudgetCeilingLearnsFromInGapPendingNotJustTheHeartbeat(t *testing.T) {
	const model = "m"
	r := New(testLogger())
	// Heartbeat says the box is EMPTY: used+queued = 0 at a huge advertised
	// budget. This is the honest report from before the burst landed.
	p := makeTokenBudgetProvider(t, r, "box", model, 100, 0, pagedAdvertisedTokens, 100)
	sendBudgetHeartbeat(r, p.ID, model, 0, pagedAdvertisedTokens)

	// Six ~20k requests dispatched inside the heartbeat gap. The coordinator
	// knows about all of them; the provider's last report does not.
	var burst int64
	for i := 0; i < 6; i++ {
		p.AddPending(&PendingRequest{
			RequestID:             "burst-" + string(rune('a'+i)),
			Model:                 model,
			EstimatedPromptTokens: pagedRequestPrompt,
			RequestedMaxTokens:    pagedRequestMaxTokens,
		})
		burst += pagedRequestTokens
	}

	// The sixth one comes back token_budget_exhausted: the affine pool is full.
	r.RecordCapacityRejectSized(p.ID, model, int(pagedRequestTokens))

	got, latched := r.BudgetCeiling(p.ID, model)
	if !latched {
		t.Fatal("a sized capacity reject must latch a ceiling")
	}
	// Heartbeat-only would have learned requestTokens − margin ≈ 19k. The
	// honest commitment is the whole burst the coordinator had placed.
	if want := burst - budgetCeilingMarginTokens; got != want {
		t.Fatalf("ceiling = %d, want %d (the full in-gap commitment, not the %d a stale heartbeat implies)",
			got, want, pagedRequestTokens-budgetCeilingMarginTokens)
	}
}

// effectiveTokenBudgetMax is the single place the min(advertised, learned)
// rule lives, and it must be zero-value safe: a snapshot built outside
// snapshotProviderLocked carries learnedTokenBudgetMax == 0, which means
// "nothing learned", never "zero budget".
func TestEffectiveTokenBudgetMaxZeroValueSafe(t *testing.T) {
	if got := effectiveTokenBudgetMax(routingSnapshot{activeTokenBudgetMax: 4096}); got != 4096 {
		t.Fatalf("unlearned snapshot = %d, want the advertised 4096", got)
	}
	learned := routingSnapshot{activeTokenBudgetMax: 4096, learnedTokenBudgetMax: 1024}
	if got := effectiveTokenBudgetMax(learned); got != 1024 {
		t.Fatalf("learned snapshot = %d, want 1024", got)
	}
	wider := routingSnapshot{activeTokenBudgetMax: 4096, learnedTokenBudgetMax: 9999}
	if got := effectiveTokenBudgetMax(wider); got != 4096 {
		t.Fatalf("a learned value above the advertised budget must not widen it: got %d, want 4096", got)
	}
}

// The ceiling is LIVE-semantics only. The structural ceiling feeds the
// fleet-level servability shed, whose "no" is a terminal 429 — a transient,
// per-box measurement must never reach it. Same split the clamp already draws.
func TestBudgetCeilingDoesNotFeedStructuralShed(t *testing.T) {
	snap := routingSnapshot{
		activeTokenBudgetMax:  500_000,
		activeTokenBudgetUsed: 100_000,
		learnedTokenBudgetMax: 120_000,
	}
	structural, known := snapshotStructuralBudget(snap)
	if !known || structural != 500_000 {
		t.Fatalf("structural budget = (%d, %v), want the raw advertised (500000, true)", structural, known)
	}
	live, known := liveRemainingBudget(snap)
	if !known || live != 20_000 {
		t.Fatalf("live remaining = (%d, %v), want (20000, true) — learned ceiling minus committed", live, known)
	}
}

// The admission gate must charge against the learned ceiling, not the raw
// heartbeat max, and must still reject everything while the one-shot clamp
// holds (the clamp is the tightest state of the same machine).
func TestFreeMemoryAdmitsHonoursLearnedCeiling(t *testing.T) {
	base := routingSnapshot{
		modelLoaded:           true,
		slotState:             "running",
		activeTokenBudgetMax:  100_000,
		activeTokenBudgetUsed: 40_000,
		totalMemoryGB:         64,
		modelSizeGB:           12,
	}
	if !freeMemoryAdmits(base, 1_000, 1_000) {
		t.Fatal("setup: a 2k request must fit 60k of raw headroom")
	}
	learned := base
	learned.learnedTokenBudgetMax = 41_000
	if !freeMemoryAdmits(learned, 500, 500) {
		t.Fatal("a 1k request must still fit a 41000 ceiling at 40000 committed")
	}
	if freeMemoryAdmits(learned, 1_000, 1_000) {
		t.Fatal("a 2k request must NOT fit a 41000 ceiling at 40000 committed")
	}
	clamped := learned
	clamped.budgetClamped = true
	if freeMemoryAdmits(clamped, 1, 1) {
		t.Fatal("an active clamp must still refuse everything")
	}
}
