package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// makeWarmPoolDiagProvider builds a cold-but-otherwise-healthy provider that
// advertises `model` while holding a DIFFERENT model in its only slot, so the
// warm-pool candidate gate sees it as a cold target.
func makeWarmPoolDiagProvider(t *testing.T, reg *Registry, id, model string, totalMemoryGB float64) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, 80)
	p.mu.Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: totalMemoryGB,
		Slots: []protocol.BackendSlotCapacity{
			{Model: "some-other-model", State: "idle"},
		},
	}
	p.mu.Unlock()
	return p
}

func setDiagFreeForLoad(p *Provider, gb float64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	v := gb
	p.BackendCapacity.FreeForLoadGB = &v
}

func modelRow(t *testing.T, diag *ProviderWarmPoolEligibility, id string) ModelWarmPoolEligibility {
	t.Helper()
	if diag == nil {
		t.Fatalf("nil diagnostics")
	}
	for _, m := range diag.Models {
		if m.ID == id {
			return m
		}
	}
	t.Fatalf("model %q not present in diagnostics (%d rows)", id, len(diag.Models))
	return ModelWarmPoolEligibility{}
}

// --- The two memory verdicts: the reason this surface exists. ---------------

// A box whose total memory is below the catalog's published min_ram_gb can never
// be pre-loaded with the model, and must say so PERMANENTLY — this is the
// distinction the raw cold_providers count cannot express.
func TestWarmPoolEligibilityReportsPermanentTooLarge(t *testing.T) {
	reg := New(testLogger())
	model := "diag-too-large"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 96, SizeGB: 40}})
	p := makeWarmPoolDiagProvider(t, reg, "small-box", model, 32)

	diag := reg.WarmPoolEligibility(p.ID, time.Now())
	row := modelRow(t, diag, model)

	if row.Eligible {
		t.Fatalf("a 32 GB box must not be an eligible target for a 96 GB model")
	}
	if row.Blocker != WarmPoolBlockerModelTooLarge {
		t.Fatalf("blocker = %q, want %q", row.Blocker, WarmPoolBlockerModelTooLarge)
	}
	if !row.Permanent {
		t.Fatalf("model_too_large must be reported as permanent: it cannot clear without a hardware or catalog change")
	}
	if diag.PermanentlyBlockedModels != 1 {
		t.Fatalf("PermanentlyBlockedModels = %d, want 1", diag.PermanentlyBlockedModels)
	}
	// The operator needs the threshold they are short of, not just a verdict.
	if row.RequiredMemoryGB != 96 {
		t.Fatalf("RequiredMemoryGB = %v, want the catalog min_ram_gb 96", row.RequiredMemoryGB)
	}
	if diag.TotalMemoryGB != 32 {
		t.Fatalf("TotalMemoryGB = %v, want the reported backend total 32", diag.TotalMemoryGB)
	}
}

// A live, self-reported memory shortfall is NOT permanent: it clears on the next
// heartbeat. Conflating it with the static verdict would tell an operator to
// replace hardware over a transient condition.
func TestWarmPoolEligibilityReportsTransientNoFreeForLoad(t *testing.T) {
	reg := New(testLogger())
	model := "diag-no-free"
	// Fits statically (64 GB box, 40 GB requirement) so only the live gate can fire.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	p := makeWarmPoolDiagProvider(t, reg, "busy-box", model, 64)
	setDiagFreeForLoad(p, 2) // 30 GB weights * 1.1176 > 2 GB reported

	diag := reg.WarmPoolEligibility(p.ID, time.Now())
	row := modelRow(t, diag, model)

	if row.Blocker != WarmPoolBlockerNoFreeForLoad {
		t.Fatalf("blocker = %q, want %q", row.Blocker, WarmPoolBlockerNoFreeForLoad)
	}
	if row.Permanent {
		t.Fatalf("no_free_for_load is a live measurement and must NOT be reported as permanent")
	}
	if diag.PermanentlyBlockedModels != 0 {
		t.Fatalf("PermanentlyBlockedModels = %d, want 0", diag.PermanentlyBlockedModels)
	}
	if diag.FreeForLoadGB == nil || *diag.FreeForLoadGB != 2 {
		t.Fatalf("FreeForLoadGB not echoed back; got %v", diag.FreeForLoadGB)
	}
}

// Ample reported memory must clear the live gate rather than being excluded by
// it — the positive control for the test above.
func TestWarmPoolEligibilityAmpleFreeMemoryIsEligible(t *testing.T) {
	reg := New(testLogger())
	model := "diag-fits"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	p := makeWarmPoolDiagProvider(t, reg, "roomy-box", model, 64)
	setDiagFreeForLoad(p, 48)

	diag := reg.WarmPoolEligibility(p.ID, time.Now())
	row := modelRow(t, diag, model)

	if !row.Eligible {
		t.Fatalf("expected eligible, got blocker %q (%s)", row.Blocker, row.BlockerDescription)
	}
	if row.Blocker != WarmPoolBlockerNone {
		t.Fatalf("an eligible row must carry no blocker, got %q", row.Blocker)
	}
	if diag.EligibleModels != 1 {
		t.Fatalf("EligibleModels = %d, want 1", diag.EligibleModels)
	}
}

// A machine reporting no free_for_load_gb at all (older version) must fall back
// to the static gate only — the live gate must fail OPEN, never closed.
func TestWarmPoolEligibilityUnreportedFreeMemoryFailsOpen(t *testing.T) {
	reg := New(testLogger())
	model := "diag-legacy"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	p := makeWarmPoolDiagProvider(t, reg, "legacy-box", model, 64)
	// Deliberately no FreeForLoadGB set.

	diag := reg.WarmPoolEligibility(p.ID, time.Now())
	row := modelRow(t, diag, model)

	if !row.Eligible {
		t.Fatalf("a machine that reports no free_for_load_gb must not be excluded by the live gate; got %q", row.Blocker)
	}
	if diag.FreeForLoadGB != nil {
		t.Fatalf("FreeForLoadGB should be nil when unreported, got %v", *diag.FreeForLoadGB)
	}
}

// --- Transient state, and the ordering that decides which reason wins. ------

// A busy machine is not_idle, and that must win over the memory gates: the
// provider deflates its reported free memory while serving, so attributing a
// busy box to no_free_for_load would blame memory for a queueing condition.
func TestWarmPoolEligibilityBusyMachineReportsNotIdleNotMemory(t *testing.T) {
	reg := New(testLogger())
	model := "diag-busy"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	p := makeWarmPoolDiagProvider(t, reg, "serving-box", model, 64)
	setDiagFreeForLoad(p, 1) // would also trip no_free_for_load
	p.mu.Lock()
	p.BackendCapacity.Slots[0].NumRunning = 1
	p.mu.Unlock()

	row := modelRow(t, reg.WarmPoolEligibility(p.ID, time.Now()), model)
	if row.Blocker != WarmPoolBlockerNotIdle {
		t.Fatalf("blocker = %q, want %q (not_idle is evaluated before the memory gates)", row.Blocker, WarmPoolBlockerNotIdle)
	}
	if row.Permanent {
		t.Fatalf("not_idle must not be permanent")
	}
}

// A stale attestation challenge must be reported as its own reason rather than
// collapsing into a memory verdict.
func TestWarmPoolEligibilityReportsStaleChallenge(t *testing.T) {
	reg := New(testLogger())
	model := "diag-stale"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	p := makeWarmPoolDiagProvider(t, reg, "stale-box", model, 64)
	setDiagFreeForLoad(p, 48)
	p.mu.Lock()
	p.LastChallengeVerified = time.Now().Add(-challengeFreshnessMaxAge - time.Minute)
	p.mu.Unlock()

	diag := reg.WarmPoolEligibility(p.ID, time.Now())
	row := modelRow(t, diag, model)
	if row.Blocker != WarmPoolBlockerStaleChallenge {
		t.Fatalf("blocker = %q, want %q", row.Blocker, WarmPoolBlockerStaleChallenge)
	}
	if diag.ChallengeMaxAgeSeconds != int(challengeFreshnessMaxAge.Seconds()) {
		t.Fatalf("ChallengeMaxAgeSeconds = %d, want %d — a client renders 'N of M minutes' against it",
			diag.ChallengeMaxAgeSeconds, int(challengeFreshnessMaxAge.Seconds()))
	}
}

// An already-loaded model is not a warming candidate, and must be
// distinguishable from an excluded one.
func TestWarmPoolEligibilityWarmModelIsNotAnEligibilityFailure(t *testing.T) {
	reg := New(testLogger())
	model := "diag-warm"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	// makeSchedulerProvider leaves the model itself "running" in the slot.
	p := makeSchedulerProvider(t, reg, "warm-box", model, 80)

	diag := reg.WarmPoolEligibility(p.ID, time.Now())
	row := modelRow(t, diag, model)
	if !row.Warm {
		t.Fatalf("expected the model to be reported warm")
	}
	if row.Eligible {
		t.Fatalf("a warm model must not also be reported as an eligible warming target")
	}
	if row.Blocker != WarmPoolBlockerAlreadyWarm {
		t.Fatalf("blocker = %q, want %q", row.Blocker, WarmPoolBlockerAlreadyWarm)
	}
	if row.Permanent {
		t.Fatalf("already_warm must never be permanent")
	}
	if diag.WarmModels != 1 {
		t.Fatalf("WarmModels = %d, want 1", diag.WarmModels)
	}
}

// --- Structural guarantees -------------------------------------------------

// The verdict must be PER MODEL: one machine can be permanently too small for
// one build and an eligible target for another, and a single machine-level
// verdict would erase exactly that distinction.
func TestWarmPoolEligibilityIsPerModel(t *testing.T) {
	reg := New(testLogger())
	big, small := "diag-big-model", "diag-small-model"
	reg.SetModelCatalog([]CatalogEntry{
		{ID: big, MinRAMGB: 128, SizeGB: 60},
		{ID: small, MinRAMGB: 16, SizeGB: 8},
	})
	p := makeWarmPoolDiagProvider(t, reg, "mixed-box", big, 64)
	p.mu.Lock()
	p.Models = []protocol.ModelInfo{{ID: big}, {ID: small}}
	p.mu.Unlock()
	setDiagFreeForLoad(p, 48)

	diag := reg.WarmPoolEligibility(p.ID, time.Now())
	if len(diag.Models) != 2 {
		t.Fatalf("expected 2 model rows, got %d", len(diag.Models))
	}
	if b := modelRow(t, diag, big); !b.Permanent || b.Blocker != WarmPoolBlockerModelTooLarge {
		t.Fatalf("big model: blocker=%q permanent=%v, want permanent model_too_large", b.Blocker, b.Permanent)
	}
	if s := modelRow(t, diag, small); !s.Eligible {
		t.Fatalf("small model should be eligible on the same box, got %q", s.Blocker)
	}
	// Rows are sorted so a client renders a stable list.
	if diag.Models[0].ID > diag.Models[1].ID {
		t.Fatalf("model rows must be sorted by id, got %s then %s", diag.Models[0].ID, diag.Models[1].ID)
	}
}

// The diagnostic must delegate to the planner's own predicate, not
// re-implement it. Asserting agreement across every advertised model is what
// makes a future edit to one gate fail here rather than drift silently.
func TestWarmPoolEligibilityAgreesWithThePlannerPredicate(t *testing.T) {
	reg := New(testLogger())
	model := "diag-agreement"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})

	cases := []struct {
		name   string
		mutate func(p *Provider)
	}{
		{"healthy-cold", func(p *Provider) { setDiagFreeForLoad(p, 48) }},
		{"no-free-for-load", func(p *Provider) { setDiagFreeForLoad(p, 1) }},
		{"busy", func(p *Provider) {
			setDiagFreeForLoad(p, 48)
			p.mu.Lock()
			p.BackendCapacity.Slots[0].NumWaiting = 2
			p.mu.Unlock()
		}},
		{"thermal-critical", func(p *Provider) {
			setDiagFreeForLoad(p, 48)
			p.mu.Lock()
			p.SystemMetrics.ThermalState = "critical"
			p.mu.Unlock()
		}},
		{"untrusted", func(p *Provider) {
			setDiagFreeForLoad(p, 48)
			p.mu.Lock()
			p.RuntimeVerified = false
			p.mu.Unlock()
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := makeWarmPoolDiagProvider(t, reg, "agree-"+tc.name, model, 64)
			tc.mutate(p)
			now := time.Now()

			row := modelRow(t, reg.WarmPoolEligibility(p.ID, now), model)

			// Ask the planner directly, under the same locks it uses.
			reg.mu.RLock()
			p.mu.Lock()
			_, plannerEligible := reg.warmPoolCandidateLocked(p, model, now)
			p.mu.Unlock()
			reg.mu.RUnlock()

			if row.Eligible != plannerEligible {
				t.Fatalf("diagnostic says eligible=%v but the planner says %v (blocker %q) — the two must not disagree",
					row.Eligible, plannerEligible, row.Blocker)
			}
		})
	}
}

// Every internal reason must map to an exported blocker, and only the eligible
// sentinel may map to "no blocker". Without this a newly added warmColdReason
// would fall through the mapping and read as ELIGIBLE on an operator's screen.
func TestWarmPoolBlockerMappingIsClosedOverEveryReason(t *testing.T) {
	all := []warmColdReason{
		warmColdEligible,
		warmColdOfflineUntrust,
		warmColdPendingLoad,
		warmColdNotIdle,
		warmColdThermal,
		warmColdTrust,
		warmColdStaleChallenge,
		warmColdNotServing,
		warmColdDedicated,
		warmColdTooLarge,
		warmColdNoFreeForLoad,
	}
	seen := make(map[WarmPoolBlocker]warmColdReason, len(all))
	for _, reason := range all {
		b := warmPoolBlockerFor(reason)
		if reason != warmColdEligible && b == WarmPoolBlockerNone {
			t.Fatalf("reason %q maps to the empty blocker, which reads as ELIGIBLE", reason)
		}
		if prev, dup := seen[b]; dup {
			t.Fatalf("blocker %q is produced by two reasons (%q and %q)", b, prev, reason)
		}
		seen[b] = reason
		if b.Description() == "" {
			t.Fatalf("blocker %q has no operator-facing description", b)
		}
		if b != WarmPoolBlockerNone && b.Description() == string(b) {
			t.Fatalf("blocker %q falls through to its raw wire string instead of a description", b)
		}
	}
	// Only the static hardware verdict is permanent.
	for b, reason := range seen {
		wantPermanent := b == WarmPoolBlockerModelTooLarge
		if b.Permanent() != wantPermanent {
			t.Fatalf("blocker %q (reason %q) Permanent()=%v, want %v", b, reason, b.Permanent(), wantPermanent)
		}
	}
}

// An unmapped reason must NOT silently read as eligible.
func TestWarmPoolBlockerUnknownReasonIsNotEligible(t *testing.T) {
	b := warmPoolBlockerFor(warmColdReason("some_future_reason"))
	if b == WarmPoolBlockerNone {
		t.Fatalf("an unmapped reason must not map to the eligible sentinel")
	}
	if b.Permanent() {
		t.Fatalf("an unmapped reason must not be assumed permanent")
	}
}

// requiredMemoryGBLocked must mirror modelFitsHardware's precedence, or the
// number shown to an operator is not the number the gate applied.
func TestRequiredMemoryGBMirrorsTheFitGatePrecedence(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{
		{ID: "both", MinRAMGB: 48, SizeGB: 30},
		{ID: "size-only", SizeGB: 30},
		{ID: "neither"},
	})
	reg.mu.RLock()
	defer reg.mu.RUnlock()

	if got := reg.requiredMemoryGBLocked("both"); got != 48 {
		t.Fatalf("min_ram_gb must win: got %v, want 48", got)
	}
	if got := reg.requiredMemoryGBLocked("size-only"); got != 30*modelMemoryHeadroomFactor {
		t.Fatalf("size heuristic: got %v, want %v", got, 30*modelMemoryHeadroomFactor)
	}
	if got := reg.requiredMemoryGBLocked("neither"); got != 0 {
		t.Fatalf("an unpublished requirement must report 0 (gate disabled), got %v", got)
	}
}

// An unknown provider id must not panic or invent a verdict.
func TestWarmPoolEligibilityUnknownProviderIsNil(t *testing.T) {
	reg := New(testLogger())
	if diag := reg.WarmPoolEligibility("nope", time.Now()); diag != nil {
		t.Fatalf("expected nil for an unconnected provider, got %+v", diag)
	}
}

// The aggregate side: the controller's reason tally must reach the utilization
// snapshot instead of being discarded.
func TestNetworkUtilizationCarriesColdDisqualifiers(t *testing.T) {
	caps := []ModelCapacity{{ModelID: "m", ColdProviders: 9, WarmProviders: 1}}
	snaps := []WarmPoolSnapshot{{
		Model:              "m",
		WarmProviders:      1,
		EligibleCold:       2,
		ColdIneligible:     7,
		QualityConcurrency: 2,
		ColdDisqualifiers:  map[string]int{"model_too_large": 6, "not_idle": 1},
	}}
	out := computeNetworkUtilization(caps, snaps, FleetCapacity{}, time.Now(), time.Now())
	if len(out.Models) != 1 {
		t.Fatalf("expected 1 model row, got %d", len(out.Models))
	}
	row := out.Models[0]
	if row.EligibleCold != 2 || row.ColdIneligible != 7 {
		t.Fatalf("eligible_cold=%d cold_ineligible=%d, want 2 and 7", row.EligibleCold, row.ColdIneligible)
	}
	if row.ColdDisqualifiers["model_too_large"] != 6 {
		t.Fatalf("cold_disqualifiers not propagated: %v", row.ColdDisqualifiers)
	}
	// The pre-existing raw count must be untouched by this addition.
	if row.ColdProviders != 9 {
		t.Fatalf("cold_providers = %d, want the unchanged raw count 9", row.ColdProviders)
	}
}
