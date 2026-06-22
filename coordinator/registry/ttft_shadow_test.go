package registry

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// withTTFTConfig snapshots and restores the package-level Phase-0 TTFT knobs so
// each test runs in isolation (Go runs package tests sequentially, so resetting
// in Cleanup is sufficient).
func withTTFTConfig(t *testing.T, alpha, deadlineBaseMs float64, mode TTFTAdmissionMode) {
	t.Helper()
	prevAlpha := TTFTOccupancyAlpha()
	prevBase := TTFTDeadlineBaseMs()
	prevMode := TTFTAdmissionModeValue()
	t.Cleanup(func() {
		SetTTFTOccupancyAlpha(prevAlpha)
		SetTTFTDeadlineBaseMs(prevBase)
		SetTTFTAdmissionMode(prevMode)
	})
	SetTTFTOccupancyAlpha(alpha)
	if deadlineBaseMs > 0 {
		SetTTFTDeadlineBaseMs(deadlineBaseMs)
	}
	SetTTFTAdmissionMode(mode)
}

// TestTTFTOccupancyTermZeroWhenAlphaZero pins the behavior-neutral default: with
// alpha=0 the occupancy term contributes nothing, so ttftMsFromSnapshot is
// byte-for-byte the pre-Phase-0 estimate no matter how herded the box is.
func TestTTFTOccupancyTermZeroWhenAlphaZero(t *testing.T) {
	if TTFTOccupancyAlpha() != 0 {
		t.Fatalf("default occupancy alpha must be 0, got %f", TTFTOccupancyAlpha())
	}
	snap := routingSnapshot{
		hasBackendCapacity: true,
		slotState:          "running",
		decodeTPS:          55,
		prefillTPS:         660,
		backendRunning:     8,
		pendingForModel:    8,
	}
	if got := ttftOccupancyMs(snap); got != 0 {
		t.Fatalf("ttftOccupancyMs must be 0 when alpha=0, got %f", got)
	}
}

// TestTTFTEstimateOccupancyTermActiveAndMonotonic exercises the flag ON via the
// SHADOW estimate (occupancyAwareTTFTMsFromSnapshot — the only place the term is
// added; ttftMsFromSnapshot stays occupancy-free, see Fix D): the occupancy term
// raises the estimate, the estimate is strictly increasing in occupancy, and it
// crosses the verified ~10s deadline at a knee. It also pins the safety invariant
// at the unit level — ttftMsFromSnapshot (the live input) is unchanged by alpha.
func TestTTFTEstimateOccupancyTermActiveAndMonotonic(t *testing.T) {
	withTTFTConfig(t, 45, defaultTTFTDeadlineBaseMs, TTFTAdmissionOff)

	mk := func(running int) routingSnapshot {
		return routingSnapshot{
			hasBackendCapacity: true,
			slotState:          "running",
			decodeTPS:          55, // gpt-oss solo ~55 tok/s
			prefillTPS:         660,
			backendRunning:     running,
		}
	}
	const reqPrompt = 1000

	// The occupancy term must add to the SHADOW estimate at b>0 (compare alpha on
	// vs off). The LIVE estimate (ttftMsFromSnapshot) must NOT move with alpha.
	SetTTFTOccupancyAlpha(0)
	liveOff := ttftMsFromSnapshot(mk(4), reqPrompt)
	shadowOff := occupancyAwareTTFTMsFromSnapshot(mk(4), reqPrompt)
	SetTTFTOccupancyAlpha(45)
	liveOn := ttftMsFromSnapshot(mk(4), reqPrompt)
	shadowOn := occupancyAwareTTFTMsFromSnapshot(mk(4), reqPrompt)
	if liveOn != liveOff {
		t.Fatalf("ttftMsFromSnapshot must be occupancy-FREE (invariant): alpha=0 %f vs alpha=45 %f", liveOff, liveOn)
	}
	if shadowOff != liveOff {
		t.Fatalf("at alpha=0 the shadow estimate must equal the base: shadow=%f base=%f", shadowOff, liveOff)
	}
	if shadowOn <= shadowOff {
		t.Fatalf("occupancy term must raise the shadow estimate at b=4: with=%f base=%f", shadowOn, shadowOff)
	}

	// Strictly increasing in occupancy, crossing the deadline at a knee.
	deadline := ttftDeadlineMsForPrompt(reqPrompt)
	last := -1.0
	knee := -1
	for b := 0; b <= 8; b++ {
		est := occupancyAwareTTFTMsFromSnapshot(mk(b), reqPrompt)
		if est <= last {
			t.Fatalf("estimate not strictly increasing at b=%d: %f <= %f", b, est, last)
		}
		last = est
		if knee < 0 && est > deadline {
			knee = b
		}
	}
	if knee < 1 || knee > 8 {
		t.Fatalf("estimate should cross the %.0fms deadline at a knee in b=1..8, got knee=%d", deadline, knee)
	}
	// b=0 (idle) must stay well under the deadline — route-to-idle is preserved.
	if idle := occupancyAwareTTFTMsFromSnapshot(mk(0), reqPrompt); idle > deadline {
		t.Fatalf("idle box (b=0) must be under the deadline, got %f > %f", idle, deadline)
	}
}

// TestTTFTOccupancyTermRateUsesOccupancyNotBackendRunning pins Fix C: in the herd
// case (pendingForModel > backend_running) the occupancy term must project the
// per-request decode rate at the batch the request ACTUALLY joins (occ), not the
// stale heartbeat backend_running gauge. Charging the backend_running rate would
// divide by an idle/low-batch rate and UNDER-state the term — the opposite of
// intended — in exactly the case the term exists to measure.
func TestTTFTOccupancyTermRateUsesOccupancyNotBackendRunning(t *testing.T) {
	withTTFTConfig(t, 45, defaultTTFTDeadlineBaseMs, TTFTAdmissionOff)

	// Heartbeat still reads backend_running=2, but the coordinator has already
	// reserved 8 dispatched-not-terminal requests for this model (pendingForModel
	// =8) → occ=8. The new request joins a batch of 8, not 2.
	herd := routingSnapshot{
		hasBackendCapacity: true,
		slotState:          "running",
		decodeTPS:          55,
		prefillTPS:         660,
		backendRunning:     2,
		backendWaiting:     0,
		pendingForModel:    8,
	}
	occ := snapshotOccupancy(herd)
	if occ != 8 {
		t.Fatalf("precondition: occ should be 8 (herd), got %d", occ)
	}
	got := ttftOccupancyMs(herd)

	// Correct: rate projected at the batch the request joins (occ).
	wantRate := projectedPerRequestDecodeTPSAtBatch(herd, occ)
	want := 45 * float64(occ) * 1000.0 / wantRate
	if math.Abs(got-want) > 1e-6 {
		t.Fatalf("occupancy term must use occ for the rate: got %f want %f", got, want)
	}

	// The pre-fix rate (projected at the bare backend_running gauge) is FASTER, so
	// the buggy term would be SMALLER. Assert the fix charges strictly more.
	buggyRate := projectedPerRequestDecodeTPSAtBatch(herd, herd.backendRunning)
	buggyTerm := 45 * float64(occ) * 1000.0 / buggyRate
	if !(got > buggyTerm) {
		t.Fatalf("herd term must exceed the backend_running-rate term: got %f buggy %f", got, buggyTerm)
	}

	// At an EQUAL heartbeat gauge, a larger pending burst (higher occ) must grow
	// the term — both via the occ numerator AND the shrinking occ-projected rate.
	lowBurst := herd
	lowBurst.pendingForModel = 3 // occ = max(3, 2) = 3
	if !(ttftOccupancyMs(herd) > ttftOccupancyMs(lowBurst)) {
		t.Fatalf("term must grow with pending burst at equal backend_running: occ8=%f occ3=%f",
			ttftOccupancyMs(herd), ttftOccupancyMs(lowBurst))
	}
}

func TestParseTTFTAdmissionMode(t *testing.T) {
	cases := map[string]TTFTAdmissionMode{
		"":        TTFTAdmissionOff,
		"off":     TTFTAdmissionOff,
		"garbage": TTFTAdmissionOff,
		"shadow":  TTFTAdmissionShadow,
		" SHADOW": TTFTAdmissionShadow,
		"enforce": TTFTAdmissionEnforce,
	}
	for in, want := range cases {
		if got := ParseTTFTAdmissionMode(in); got != want {
			t.Errorf("ParseTTFTAdmissionMode(%q) = %v, want %v", in, got, want)
		}
	}
}

// TestTTFTAdmissionModeOffNoShadowEval confirms the default mode leaves the
// RoutingDecision shadow fields untouched (behavior-neutral observability).
func TestTTFTAdmissionModeOffNoShadowEval(t *testing.T) {
	withTTFTConfig(t, 45, defaultTTFTDeadlineBaseMs, TTFTAdmissionOff)
	reg := New(testLogger())
	model := "shadow-off-model"
	makeSchedulerProvider(t, reg, "p1", model, 100)

	_, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	if decision.ShadowEvaluated {
		t.Fatalf("admission mode off must not evaluate shadow: %+v", decision)
	}
	if decision.ShadowMode != "" || decision.ShadowWouldShed || decision.ShadowIdleAlternativeExists {
		t.Fatalf("shadow fields must be zero when off: %+v", decision)
	}
}

// TestTTFTShadowEvalWouldShedButStillServes is the core shadow assertion: a
// herded provider whose occupancy-aware estimate exceeds the ~10s base is flagged
// would_shed, yet the request is STILL served (the decision is unchanged). This
// is the behavior-neutral guarantee of shadow mode.
func TestTTFTShadowEvalWouldShedButStillServes(t *testing.T) {
	withTTFTConfig(t, 45, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-shed-model"
	p := makeSchedulerProvider(t, reg, "busy", model, 55)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].NumRunning = 6 // herded → occupancy-aware estimate >> 10s
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: 1000, RequestedMaxTokens: 256})
	if selected == nil || decision.ProviderID != p.ID {
		t.Fatalf("shadow mode must NOT change the decision — provider should still be served: selected=%v decision=%+v", selected, decision)
	}
	if !decision.ShadowEvaluated || decision.ShadowMode != "shadow" {
		t.Fatalf("shadow eval should be populated: %+v", decision)
	}
	if !decision.ShadowWouldShed {
		t.Fatalf("a b=6 gpt-oss box at alpha=45 should be flagged would_shed (est=%f deadline=%f)", decision.ShadowEstimateMs, decision.ShadowDeadlineMs)
	}
	if decision.ShadowEstimateMs <= decision.ShadowDeadlineMs {
		t.Fatalf("would_shed implies estimate>deadline: est=%f deadline=%f", decision.ShadowEstimateMs, decision.ShadowDeadlineMs)
	}
}

// TestTTFTShadowEvalRedirectToIdle reproduces the load-spreading failure the data
// shows: the cost lands a request on a fast-but-herded box while an
// instantly-usable loaded-idle box for the same model was routable. Shadow flags
// would_redirect_to_idle=true without changing the (herded) selection.
func TestTTFTShadowEvalRedirectToIdle(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-spread-model"

	// Fast but herded winner: occupancy=1, but so cheap it still beats the slow
	// idle box on cost.
	fastBusy := makeSchedulerProvider(t, reg, "fast-busy", model, 300)
	fastBusy.mu.Lock()
	fastBusy.BackendCapacity.Slots[0].NumRunning = 1
	fastBusy.mu.Unlock()

	// Slow, idle, loaded alternative (occupancy=0).
	makeSchedulerProvider(t, reg, "slow-idle", model, 20)

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 256})
	if selected == nil {
		t.Fatalf("expected a selection, got nil: %+v", decision)
	}
	if selected.ID != fastBusy.ID {
		t.Skipf("cost model did not pick the herded box (picked %q); spread-signal precondition not met", selected.ID)
	}
	if !decision.ShadowEvaluated {
		t.Fatalf("shadow eval should be populated: %+v", decision)
	}
	if decision.ShadowOccupancy == 0 {
		t.Fatalf("winner should be herded (occupancy>0): %+v", decision)
	}
	if !decision.ShadowIdleAlternativeExists {
		t.Fatalf("an idle loaded alternative existed; would_redirect_to_idle must be true: %+v", decision)
	}
}

// TestTTFTShadowEvalNoRedirectWhenWinnerIdle confirms the spread signal is false
// when the request already landed on an idle box (nothing better to spread to).
func TestTTFTShadowEvalNoRedirectWhenWinnerIdle(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-idle-winner-model"
	makeSchedulerProvider(t, reg, "idle", model, 100)

	_, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	if !decision.ShadowEvaluated {
		t.Fatalf("shadow eval should be populated: %+v", decision)
	}
	if decision.ShadowOccupancy != 0 {
		t.Fatalf("winner should be idle (occupancy 0): %+v", decision)
	}
	if decision.ShadowIdleAlternativeExists {
		t.Fatalf("no redirect signal expected when the winner itself is idle: %+v", decision)
	}
}

// TestTTFTOccupancyAlphaDoesNotMoveLiveCeiling pins the central HARD_REJECT safety
// invariant (Fix D): with pr.MaxTTFTMs set (HARD_REJECT semantics) and the
// occupancy term ON (alpha>0, mode=shadow), the LIVE candidate-loop ceiling is
// identical to alpha=0 — the herded box is NOT hard-rejected by the occupancy term
// and the winning decision's live TTFTMs is unchanged — while the shadow evaluator
// STILL computes the occupancy-aware would_shed at the verified ~10s base.
func TestTTFTOccupancyAlphaDoesNotMoveLiveCeiling(t *testing.T) {
	const (
		model     = "hardreject-invariant-model"
		decodeTPS = 55.0
		prompt    = 1000
		// base estimate (~1.5s) passes this ceiling; the occupancy-aware estimate
		// (~15s at occ=6) is well over the ~10s shadow deadline → would_shed.
		maxTTFT = 5000.0
	)
	mkHerded := func(reg *Registry) *Provider {
		p := makeSchedulerProvider(t, reg, "herded", model, decodeTPS)
		p.mu.Lock()
		p.BackendCapacity.Slots[0].NumRunning = 6 // occ=6
		p.mu.Unlock()
		return p
	}
	newReq := func() *PendingRequest {
		return &PendingRequest{RequestID: "r1", Model: model, EstimatedPromptTokens: prompt, RequestedMaxTokens: 256, MaxTTFTMs: maxTTFT}
	}

	// Baseline: alpha=0, no shadow. The herded box passes the 5s live ceiling.
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionOff)
	regOff := New(testLogger())
	pOff := mkHerded(regOff)
	selOff, decOff := regOff.ReserveProviderEx(model, newReq())
	if selOff == nil || decOff.ProviderID != pOff.ID {
		t.Fatalf("alpha=0: herded box must pass the live ceiling and be selected: sel=%v dec=%+v", selOff, decOff)
	}

	// alpha>0 + shadow: the SAME live ceiling must hold (selection + live TTFTMs
	// identical), proving the occupancy term never reached breakdown.TTFTMs; the
	// shadow evaluator must still flag would_shed via the occupancy-aware estimate.
	SetTTFTOccupancyAlpha(45)
	SetTTFTAdmissionMode(TTFTAdmissionShadow)
	regOn := New(testLogger())
	pOn := mkHerded(regOn)
	selOn, decOn := regOn.ReserveProviderEx(model, newReq())
	if selOn == nil || decOn.ProviderID != pOn.ID {
		t.Fatalf("alpha=45: occupancy term must NOT hard-reject the herded box (HARD_REJECT invariant): sel=%v dec=%+v", selOn, decOn)
	}
	if decOn.TTFTMs != decOff.TTFTMs {
		t.Fatalf("live TTFTMs must be identical at alpha=0 and alpha=45 (occupancy-free): off=%f on=%f", decOff.TTFTMs, decOn.TTFTMs)
	}
	if !decOn.ShadowEvaluated || !decOn.ShadowWouldShed {
		t.Fatalf("shadow must still compute occupancy-aware would_shed: %+v", decOn)
	}
	if decOn.ShadowEstimateMs <= decOn.TTFTMs {
		t.Fatalf("shadow occupancy-aware estimate must exceed the occupancy-free live TTFTMs: shadow=%f live=%f", decOn.ShadowEstimateMs, decOn.TTFTMs)
	}
}

// TestLoadedIdleAlternativeHonorsVisionGate pins Fix B: the idle shadow scan must
// apply the SAME selection gates the scheduler does. A vision request whose only
// idle peer is text-only must NOT count that peer as a spread alternative (the
// scheduler would have vision-rejected it), and the same fleet must count it for a
// text request and count a vision-capable peer for the vision request.
func TestLoadedIdleAlternativeHonorsVisionGate(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-vision-gate-model"

	// Winner is excluded by ID inside the scan; its capability is irrelevant.
	winner := makeSchedulerProvider(t, reg, "winner", model, 100)

	// The only idle peer is TEXT-ONLY for this model.
	idleText := makeSchedulerProvider(t, reg, "idle-text", model, 100)
	idleText.mu.Lock()
	idleText.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: false}}
	idleText.mu.Unlock()

	visionReq := &PendingRequest{RequestID: "rv", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, RequiresVision: true}
	textReq := &PendingRequest{RequestID: "rt", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128}

	// loadedIdleAlternativeExistsLocked requires r.mu; take it per call so the
	// makeSchedulerProvider (Register → r.mu.Lock) calls between checks don't
	// deadlock against a held lock.
	idleAlt := func(pr *PendingRequest) bool {
		reg.mu.Lock()
		defer reg.mu.Unlock()
		return reg.loadedIdleAlternativeExistsLocked(model, pr, winner)
	}

	if idleAlt(visionReq) {
		t.Fatal("vision request must NOT count a text-only idle peer as a spread alternative")
	}
	// A TEXT request on the same fleet DOES have a valid idle alternative.
	if !idleAlt(textReq) {
		t.Fatal("text request must count the text-only idle peer as a spread alternative")
	}

	// Once a VISION-capable idle peer exists, the vision request counts it.
	idleVision := makeSchedulerProvider(t, reg, "idle-vision", model, 100)
	idleVision.mu.Lock()
	idleVision.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: true}}
	idleVision.mu.Unlock()
	if !idleAlt(visionReq) {
		t.Fatal("vision request must count a vision-capable idle peer as a spread alternative")
	}
}

// TestLoadedIdleAlternativeHonorsPreferOwnerPool pins the prefer-owner owned-pool
// restriction: when prefer-owner selected an OWNED winner, the selector's pool was
// owned-only, so a PUBLIC idle peer is not a real alternative. A plain request (no
// prefer-owner) still counts the public peer, and an OWNED idle peer counts for the
// prefer-owner request.
func TestLoadedIdleAlternativeHonorsPreferOwnerPool(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-prefer-owner-model"
	const owner = "owner-account-1"

	// Owned winner (excluded by ID in the scan) — its ownership makes the
	// selector's pool owned-only for a prefer-owner request.
	winner := makeSchedulerProvider(t, reg, "owned-winner", model, 100)
	winner.mu.Lock()
	winner.AccountID = owner
	winner.mu.Unlock()

	// The only idle peer is PUBLIC (no owner).
	makeSchedulerProvider(t, reg, "public-idle", model, 100)

	idleAlt := func(pr *PendingRequest) bool {
		reg.mu.Lock()
		defer reg.mu.Unlock()
		return reg.loadedIdleAlternativeExistsLocked(model, pr, winner)
	}

	preferOwner := &PendingRequest{RequestID: "rp", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, OwnerAccountID: owner, PreferOwner: true}
	if idleAlt(preferOwner) {
		t.Fatal("prefer-owner with an owned winner must NOT count a public idle peer (owned-pool restriction)")
	}

	// A plain request (no prefer-owner) does count the public idle peer.
	plain := &PendingRequest{RequestID: "rpp", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128}
	if !idleAlt(plain) {
		t.Fatal("a plain request must count the public idle peer")
	}

	// An OWNED idle peer IS a valid prefer-owner alternative.
	ownedIdle := makeSchedulerProvider(t, reg, "owned-idle", model, 100)
	ownedIdle.mu.Lock()
	ownedIdle.AccountID = owner
	ownedIdle.mu.Unlock()
	if !idleAlt(preferOwner) {
		t.Fatal("prefer-owner must count an OWNED idle peer as a spread alternative")
	}
}

// TestLoadedIdleAlternativeHonorsAllowlist pins the provider-allowlist gate: a
// request with AllowedProviderSerials must not count an idle peer whose serial is
// not in the allowlist, but must count one whose serial is.
func TestLoadedIdleAlternativeHonorsAllowlist(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-allowlist-model"

	winner := makeSchedulerProvider(t, reg, "winner", model, 100)
	idlePeer := makeSchedulerProvider(t, reg, "idle-peer", model, 100)
	setSchedulerProviderSerial(idlePeer, "SERIAL-IDLE")

	idleAlt := func(pr *PendingRequest) bool {
		reg.mu.Lock()
		defer reg.mu.Unlock()
		return reg.loadedIdleAlternativeExistsLocked(model, pr, winner)
	}

	disallowed := &PendingRequest{RequestID: "ra", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, AllowedProviderSerials: []string{"SERIAL-OTHER"}}
	if idleAlt(disallowed) {
		t.Fatal("allowlist request must NOT count a non-allowlisted idle peer")
	}

	allowed := &PendingRequest{RequestID: "raa", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, AllowedProviderSerials: []string{"SERIAL-IDLE"}}
	if !idleAlt(allowed) {
		t.Fatal("allowlist request must count an allowlisted idle peer")
	}
}

// TestLoadedIdleAlternativeHonorsExcludeIDs pins the retry/speculative-backup
// exclusion: an idle peer that the selector excluded (passed in excludeIDs) must
// not be counted as a spread alternative.
func TestLoadedIdleAlternativeHonorsExcludeIDs(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-exclude-model"

	winner := makeSchedulerProvider(t, reg, "winner", model, 100)
	idlePeer := makeSchedulerProvider(t, reg, "idle-peer", model, 100)

	idleAlt := func(pr *PendingRequest, exclude ...string) bool {
		reg.mu.Lock()
		defer reg.mu.Unlock()
		return reg.loadedIdleAlternativeExistsLocked(model, pr, winner, exclude...)
	}

	req := &PendingRequest{RequestID: "re", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128}
	if !idleAlt(req) {
		t.Fatal("idle peer should count when not excluded")
	}
	if idleAlt(req, idlePeer.ID) {
		t.Fatal("an excluded (retry/backup) idle peer must not count as a spread alternative")
	}
}
