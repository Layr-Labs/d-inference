package registry

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
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

// A machine whose persisted state is still being restored after reconnect
// (providerStateRestoreRequiredLocked) reports state_restoring, transient.
// This reason landed on master after the diagnostic was written; the test pins
// the live path, not just the mapping table.
func TestWarmPoolEligibilityReportsStateRestoring(t *testing.T) {
	reg := New(testLogger())
	model := "diag-restoring"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	p := makeWarmPoolDiagProvider(t, reg, "restoring-box", model, 64)
	setDiagFreeForLoad(p, 48)
	p.mu.Lock()
	p.stateRestorePending = true
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "serial", PublicKey: "se"}
	p.mu.Unlock()

	row := modelRow(t, reg.WarmPoolEligibility(p.ID, time.Now()), model)
	if row.Blocker != WarmPoolBlockerStateRestoring {
		t.Fatalf("blocker = %q, want %q", row.Blocker, WarmPoolBlockerStateRestoring)
	}
	if row.Permanent {
		t.Fatalf("state_restoring must not be permanent")
	}
	if row.BlockerDescription == string(row.Blocker) {
		t.Fatalf("state_restoring has no description")
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
	seen := make(map[WarmPoolBlocker]warmColdReason, len(warmColdReasons))
	for _, reason := range warmColdReasons {
		b := warmPoolBlockerFor(reason)
		if reason != warmColdEligible && b == WarmPoolBlockerNone {
			t.Fatalf("reason %q maps to the empty blocker, which reads as ELIGIBLE", reason)
		}
		if _, mapped := warmPoolBlockers[reason]; !mapped {
			t.Fatalf("reason %q has no entry in warmPoolBlockers (falls through to its raw label)", reason)
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

// warmColdReasons must list every warmColdReason constant declared in the
// package, or the closed-set test above silently stops covering the new one.
// Parses the source rather than trusting a second hand-maintained list: this
// is exactly how `state_restoring` (added on master after this surface was
// written) escaped the mapping.
func TestWarmColdReasonsIsComplete(t *testing.T) {
	declared := warmColdReasonConstantsFromSource(t)
	listed := make(map[warmColdReason]struct{}, len(warmColdReasons))
	for _, r := range warmColdReasons {
		listed[r] = struct{}{}
	}
	for name, value := range declared {
		if _, ok := listed[value]; !ok {
			t.Errorf("constant %s (%q) is not in warmColdReasons", name, value)
		}
	}
	if len(declared) != len(warmColdReasons) {
		t.Errorf("warmColdReasons has %d entries, source declares %d warmColdReason constants", len(warmColdReasons), len(declared))
	}
}

// warmColdReasonConstantsFromSource returns name -> value for every constant of
// type warmColdReason declared in this package's non-test sources.
func warmColdReasonConstantsFromSource(t *testing.T) map[string]warmColdReason {
	t.Helper()
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi os.FileInfo) bool {
		return !strings.HasSuffix(fi.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatalf("parse package: %v", err)
	}
	out := make(map[string]warmColdReason)
	for _, pkg := range pkgs {
		for _, f := range pkg.Files {
			for _, decl := range f.Decls {
				gd, ok := decl.(*ast.GenDecl)
				if !ok || gd.Tok != token.CONST {
					continue
				}
				for _, spec := range gd.Specs {
					vs := spec.(*ast.ValueSpec)
					id, ok := vs.Type.(*ast.Ident)
					if !ok || id.Name != "warmColdReason" {
						continue
					}
					for i, name := range vs.Names {
						lit, ok := vs.Values[i].(*ast.BasicLit)
						if !ok || lit.Kind != token.STRING {
							t.Fatalf("%s: warmColdReason constant is not a string literal", name.Name)
						}
						v, err := strconv.Unquote(lit.Value)
						if err != nil {
							t.Fatalf("%s: %v", name.Name, err)
						}
						out[name.Name] = warmColdReason(v)
					}
				}
			}
		}
	}
	if len(out) == 0 {
		t.Fatalf("found no warmColdReason constants; parser filter is wrong")
	}
	return out
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

// --- Review follow-up: the published threshold must match the enforced one ----

// The no_free_for_load gate compares PADDED GiB (weights x 1.2 scanner overhead,
// decimal GB -> GiB), but weights_gb is the raw decimal catalog size. Publishing
// only the raw figure made the diagnostic contradict its own verdict near the
// boundary: 30 GB weights on a box reporting 32 GiB free reads as "30 needed, 32
// free" and yet is correctly refused, because the gate compares 33.5 > 32.
//
// This is the exact case from the review. It asserts the contradiction is gone:
// the row carries a threshold that is directly comparable to free_for_load_gb and
// that is ABOVE it, so the numbers now explain the verdict.
func TestWarmPoolEligibilityPublishesPaddedLoadThreshold(t *testing.T) {
	reg := New(testLogger())
	model := "diag-near-boundary"
	// Fits statically (64 GB box vs 40 GB min_ram_gb) so only the live gate fires.
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40, SizeGB: 30}})
	p := makeWarmPoolDiagProvider(t, reg, "boundary-box", model, 64)
	setDiagFreeForLoad(p, 32)

	diag := reg.WarmPoolEligibility(p.ID, time.Now())
	row := modelRow(t, diag, model)

	// Precondition: this is the near-boundary shape, i.e. raw size LOOKS like it
	// fits. Without this the test could pass for the wrong reason.
	if !(row.WeightsGB < *diag.FreeForLoadGB) {
		t.Fatalf("test shape wrong: raw weights %v must look like it fits free %v",
			row.WeightsGB, *diag.FreeForLoadGB)
	}
	if row.Blocker != WarmPoolBlockerNoFreeForLoad {
		t.Fatalf("blocker = %q, want %q", row.Blocker, WarmPoolBlockerNoFreeForLoad)
	}
	// The published threshold must be the one the gate applied, and must explain
	// the refusal by exceeding the reported free memory.
	if row.LoadThresholdGiB <= *diag.FreeForLoadGB {
		t.Fatalf("load_threshold_gib = %v must exceed free_for_load_gb = %v to explain no_free_for_load",
			row.LoadThresholdGiB, *diag.FreeForLoadGB)
	}
	// And it must equal the gate's own arithmetic exactly, not an approximation.
	want := 30 * coldLoadCatalogGBToMemGiB
	if row.LoadThresholdGiB != want {
		t.Fatalf("load_threshold_gib = %v, want %v (the gate's own conversion)", row.LoadThresholdGiB, want)
	}
	// Raw catalog size is still reported: it is what the operator sees on disk.
	if row.WeightsGB != 30 {
		t.Fatalf("weights_gb = %v, want the raw catalog 30", row.WeightsGB)
	}
}

// The published threshold must agree with the gate across the boundary in BOTH
// directions, including the admit side, so the two cannot drift apart.
func TestLoadThresholdAgreesWithTheGate(t *testing.T) {
	for _, tc := range []struct {
		name      string
		sizeGB    float64
		freeGB    float64
		wantAdmit bool
	}{
		{"raw fits but padded does not", 30, 32, false},
		{"padded fits with margin", 28, 32, true},
		{"exactly at the padded threshold", 10, 10 * coldLoadCatalogGBToMemGiB, true},
		{"a hair under the padded threshold", 10, 10*coldLoadCatalogGBToMemGiB - 0.01, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			free := tc.freeGB
			admit, reported := reportedFreeForLoadAdmits(tc.sizeGB, &free)
			if !reported {
				t.Fatalf("gate did not evaluate")
			}
			if admit != tc.wantAdmit {
				t.Fatalf("gate admit = %v, want %v", admit, tc.wantAdmit)
			}
			// The published threshold alone must predict the gate's verdict.
			threshold := loadThresholdGiB(tc.sizeGB)
			if predicted := threshold <= free; predicted != admit {
				t.Fatalf("published threshold %v vs free %v predicts admit=%v, gate says %v",
					threshold, free, predicted, admit)
			}
		})
	}
}

// An unpublished catalog size disables the live gate, so there is no threshold to
// publish. It must be omitted rather than reported as 0, which would read as
// "needs no memory".
func TestLoadThresholdOmittedWhenSizeUnpublished(t *testing.T) {
	if got := loadThresholdGiB(0); got != 0 {
		t.Fatalf("loadThresholdGiB(0) = %v, want 0", got)
	}
	reg := New(testLogger())
	model := "diag-no-size"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, MinRAMGB: 40}})
	p := makeWarmPoolDiagProvider(t, reg, "no-size-box", model, 64)
	setDiagFreeForLoad(p, 48)

	row := modelRow(t, reg.WarmPoolEligibility(p.ID, time.Now()), model)
	if row.LoadThresholdGiB != 0 {
		t.Fatalf("load_threshold_gib = %v, want 0 when the catalog publishes no size", row.LoadThresholdGiB)
	}
}

// --- Review follow-up: warm-pool-only models must survive the join -----------

// ModelCapacitySnapshot admits only publicly-routable providers, so a model whose
// every provider is private/untrusted/stale-challenged yields NO capacity row —
// while the warm-pool snapshot still records it plus the disqualifiers explaining
// exactly that. Iterating capacity rows alone dropped the model and its
// cold_disqualifiers from /v1/admin/utilization at the moment the aggregate
// diagnosis is most useful.
func TestUtilizationPreservesWarmPoolOnlyModels(t *testing.T) {
	caps := []ModelCapacity{{ModelID: "routable", ColdProviders: 2, WarmProviders: 1}}
	snaps := []WarmPoolSnapshot{
		{
			Model: "routable", WarmProviders: 1, EligibleCold: 1,
			ColdIneligible: 1, QualityConcurrency: 2,
			ColdDisqualifiers: map[string]int{"not_idle": 1},
		},
		{
			// No capacity row: every provider is filtered from the public feed.
			Model: "warm-pool-only", WarmProviders: 0, EligibleCold: 0,
			ColdIneligible: 4, QualityConcurrency: 1,
			ColdDisqualifiers: map[string]int{"stale_challenge": 3, "offline_untrusted_private": 1},
		},
	}
	out := computeNetworkUtilization(caps, snaps, FleetCapacity{}, time.Now(), time.Now())

	byModel := make(map[string]ModelUtilization, len(out.Models))
	for _, m := range out.Models {
		byModel[m.Model] = m
	}
	row, ok := byModel["warm-pool-only"]
	if !ok {
		t.Fatalf("warm-pool-only model dropped from utilization; rows = %v", byModel)
	}
	if row.ColdIneligible != 4 {
		t.Fatalf("cold_ineligible = %d, want 4", row.ColdIneligible)
	}
	if row.ColdDisqualifiers["stale_challenge"] != 3 {
		t.Fatalf("cold_disqualifiers lost: %v", row.ColdDisqualifiers)
	}
	if !row.HasWarmData {
		t.Fatalf("has_warm_data must be true for a snapshot-only row")
	}
	// The routable model must be entirely unaffected.
	if r := byModel["routable"]; r.ColdIneligible != 1 || r.ColdProviders != 2 {
		t.Fatalf("routable row disturbed: %+v", r)
	}
}

// A snapshot-only row has no routable serving capacity, so it must not move the
// network-wide aggregates or claim the bottleneck. Those are defined over
// observable capacity; changing them is a separate decision from fixing a
// reporting omission.
func TestWarmPoolOnlyRowDoesNotDisturbAggregates(t *testing.T) {
	caps := []ModelCapacity{{ModelID: "routable", ActiveRequests: 3, QueuedRequests: 1, WarmProviders: 2}}
	base := []WarmPoolSnapshot{{
		Model: "routable", WarmProviders: 2, QualityConcurrency: 2,
		DemandConcurrency: 2, SpillArrivalRate: 0.5,
	}}
	withExtra := append(append([]WarmPoolSnapshot{}, base...), WarmPoolSnapshot{
		Model: "warm-pool-only", ColdIneligible: 5, QualityConcurrency: 1,
		// Deliberately carries demand and spill: it still must not be summed.
		DemandConcurrency: 99, SpillArrivalRate: 42,
	})

	before := computeNetworkUtilization(caps, base, FleetCapacity{}, time.Now(), time.Now())
	after := computeNetworkUtilization(caps, withExtra, FleetCapacity{}, time.Now(), time.Now())

	if len(after.Models) != len(before.Models)+1 {
		t.Fatalf("expected exactly one extra row, got %d vs %d", len(after.Models), len(before.Models))
	}
	if after.DemandConcurrency != before.DemandConcurrency {
		t.Fatalf("demand_concurrency moved: %v -> %v", before.DemandConcurrency, after.DemandConcurrency)
	}
	if after.ServingCapacity != before.ServingCapacity {
		t.Fatalf("serving_capacity moved: %v -> %v", before.ServingCapacity, after.ServingCapacity)
	}
	if after.SpillArrivalRate != before.SpillArrivalRate {
		t.Fatalf("spill_arrival_rate moved: %v -> %v", before.SpillArrivalRate, after.SpillArrivalRate)
	}
	if after.Utilization != before.Utilization {
		t.Fatalf("headline utilization moved: %v -> %v", before.Utilization, after.Utilization)
	}
	if after.BottleneckModel != before.BottleneckModel {
		t.Fatalf("bottleneck model changed to %q (was %q)", after.BottleneckModel, before.BottleneckModel)
	}
	if after.ActiveRequests != before.ActiveRequests || after.QueuedRequests != before.QueuedRequests {
		t.Fatalf("request counts moved")
	}
}

// Snapshot-only rows must be deterministically ordered: a map walk would shuffle
// them between polls and make the dashboard flicker.
func TestWarmPoolOnlyRowsAreDeterministicallyOrdered(t *testing.T) {
	snaps := []WarmPoolSnapshot{
		{Model: "zeta", ColdIneligible: 1},
		{Model: "alpha", ColdIneligible: 1},
		{Model: "mu", ColdIneligible: 1},
	}
	var first []string
	for i := 0; i < 20; i++ {
		out := computeNetworkUtilization(nil, snaps, FleetCapacity{}, time.Now(), time.Now())
		got := make([]string, 0, len(out.Models))
		for _, m := range out.Models {
			got = append(got, m.Model)
		}
		if i == 0 {
			first = got
			continue
		}
		if len(got) != len(first) {
			t.Fatalf("row count varied: %v vs %v", got, first)
		}
		for j := range got {
			if got[j] != first[j] {
				t.Fatalf("row order varied between runs: %v vs %v", got, first)
			}
		}
	}
	if len(first) != 3 || first[0] != "alpha" || first[2] != "zeta" {
		t.Fatalf("rows not sorted by model id: %v", first)
	}
}
