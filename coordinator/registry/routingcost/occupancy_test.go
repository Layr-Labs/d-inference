package routingcost

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

// TestTTFTOccupancyTermZeroWhenAlphaZero pins the behavior-neutral default: with
// alpha=0 the occupancy term contributes nothing, so RawTTFTMs is
// byte-for-byte the pre-Phase-0 estimate no matter how herded the box is.
func TestTTFTOccupancyTermZeroWhenAlphaZero(t *testing.T) {
	if routingPolicy.TTFTOccupancyAlpha() != 0 {
		t.Fatalf("default occupancy alpha must be 0, got %f", routingPolicy.TTFTOccupancyAlpha())
	}
	snap := routingSnapshot{
		HasBackendCapacity: true,
		SlotState:          "running",
		DecodeTPS:          55,
		PrefillTPS:         660,
		BackendRunning:     8,
		PendingForModel:    8,
	}
	if got := routingPolicy.OccupancyMs(snapPtr(snap)); got != 0 {
		t.Fatalf("ttftOccupancyMs must be 0 when alpha=0, got %f", got)
	}
}

// TestTTFTEstimateOccupancyTermActiveAndMonotonic exercises the flag ON via the
// SHADOW estimate (Policy.OccupancyAwareTTFTMs — the only place the term is
// added; RawTTFTMs stays occupancy-free, see Fix D): the occupancy term
// raises the estimate, the estimate is strictly increasing in occupancy, and it
// crosses the verified ~10s deadline at a knee. It also pins the safety invariant
// at the unit level — RawTTFTMs (the live input) is unchanged by alpha.
func TestTTFTEstimateOccupancyTermActiveAndMonotonic(t *testing.T) {
	withTTFTConfig(t, 45, DefaultTTFTDeadlineBaseMs, TTFTAdmissionOff)

	mk := func(running int) routingSnapshot {
		return routingSnapshot{
			HasBackendCapacity: true,
			SlotState:          "running",
			DecodeTPS:          55, // gpt-oss solo ~55 tok/s
			PrefillTPS:         660,
			BackendRunning:     running,
		}
	}
	const reqPrompt = 1000
	const model = "ordinary-shadow-model"

	// The occupancy term must add to the SHADOW estimate at b>0 (compare alpha on
	// vs off). The LIVE estimate (RawTTFTMs) must NOT move with alpha.
	routingPolicy.SetTTFTOccupancyAlpha(0)
	liveOff := RawTTFTMs(snapPtr(mk(4)), reqPrompt)
	shadowOff := routingPolicy.OccupancyAwareTTFTMs(snapPtr(mk(4)), reqPrompt)
	routingPolicy.SetTTFTOccupancyAlpha(45)
	liveOn := RawTTFTMs(snapPtr(mk(4)), reqPrompt)
	shadowOn := routingPolicy.OccupancyAwareTTFTMs(snapPtr(mk(4)), reqPrompt)
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
	deadline := routingPolicy.ShadowDeadlineMs(model, reqPrompt)
	last := -1.0
	knee := -1
	for b := 0; b <= 8; b++ {
		est := routingPolicy.OccupancyAwareTTFTMs(snapPtr(mk(b)), reqPrompt)
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
	if idle := routingPolicy.OccupancyAwareTTFTMs(snapPtr(mk(0)), reqPrompt); idle > deadline {
		t.Fatalf("idle box (b=0) must be under the deadline, got %f > %f", idle, deadline)
	}
}

func TestTTFTShadowDeadlineUsesExactModelPolicy(t *testing.T) {
	withTTFTConfig(t, 0, DefaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	const promptTokens = 321

	if got, want := routingPolicy.ShadowDeadlineMs(
		"ordinary-shadow-model", promptTokens,
	), 10_321.0; got != want {
		t.Fatalf("ordinary shadow deadline = %.0fms, want %.0fms", got, want)
	}
	if got, want := routingPolicy.ShadowDeadlineMs(
		modelpolicy.Qwen3VL30BA3BInstructModelID, promptTokens,
	), 5_321.0; got != want {
		t.Fatalf("Qwen3-VL shadow deadline = %.0fms, want %.0fms", got, want)
	}
	if got, want := routingPolicy.ShadowDeadlineMs(
		modelpolicy.Qwen3VL30BA3BInstructModelID+"-preview", promptTokens,
	), 10_321.0; got != want {
		t.Fatalf("lookalike shadow deadline = %.0fms, want %.0fms", got, want)
	}
	routingPolicy.SetTTFTDeadlineBaseMs(3_000)
	if got, want := routingPolicy.ShadowDeadlineMs(
		modelpolicy.Qwen3VL30BA3BInstructModelID, promptTokens,
	), 3_321.0; got != want {
		t.Fatalf("tight global shadow deadline = %.0fms, want %.0fms", got, want)
	}
}

// TestTTFTOccupancyTermRateUsesOccupancyNotBackendRunning pins Fix C: in the herd
// case (pendingForModel > backend_running) the occupancy term must project the
// per-request decode rate at the batch the request ACTUALLY joins (occ), not the
// stale heartbeat backend_running gauge. Charging the backend_running rate would
// divide by an idle/low-batch rate and UNDER-state the term — the opposite of
// intended — in exactly the case the term exists to measure.
func TestTTFTOccupancyTermRateUsesOccupancyNotBackendRunning(t *testing.T) {
	withTTFTConfig(t, 45, DefaultTTFTDeadlineBaseMs, TTFTAdmissionOff)

	// Heartbeat still reads backend_running=2, but the coordinator has already
	// reserved 8 dispatched-not-terminal requests for this model (pendingForModel
	// =8) → occ=8. The new request joins a batch of 8, not 2.
	herd := routingSnapshot{
		HasBackendCapacity: true,
		SlotState:          "running",
		DecodeTPS:          55,
		PrefillTPS:         660,
		BackendRunning:     2,
		BackendWaiting:     0,
		PendingForModel:    8,
	}
	occ := Occupancy(snapPtr(herd))
	if occ != 8 {
		t.Fatalf("precondition: occ should be 8 (herd), got %d", occ)
	}
	got := routingPolicy.OccupancyMs(snapPtr(herd))

	// Correct: rate projected at the batch the request joins (occ).
	wantRate := ProjectedPerRequestDecodeTPSAtBatch(snapPtr(herd), occ)
	want := 45 * float64(occ) * 1000.0 / wantRate
	if math.Abs(got-want) > 1e-6 {
		t.Fatalf("occupancy term must use occ for the rate: got %f want %f", got, want)
	}

	// The pre-fix rate (projected at the bare backend_running gauge) is FASTER, so
	// the buggy term would be SMALLER. Assert the fix charges strictly more.
	buggyRate := ProjectedPerRequestDecodeTPSAtBatch(snapPtr(herd), herd.BackendRunning)
	buggyTerm := 45 * float64(occ) * 1000.0 / buggyRate
	if !(got > buggyTerm) {
		t.Fatalf("herd term must exceed the backend_running-rate term: got %f buggy %f", got, buggyTerm)
	}

	// At an EQUAL heartbeat gauge, a larger pending burst (higher occ) must grow
	// the term — both via the occ numerator AND the shrinking occ-projected rate.
	lowBurst := herd
	lowBurst.PendingForModel = 3 // occ = max(3, 2) = 3
	if !(routingPolicy.OccupancyMs(snapPtr(herd)) > routingPolicy.OccupancyMs(snapPtr(lowBurst))) {
		t.Fatalf("term must grow with pending burst at equal backend_running: occ8=%f occ3=%f",
			routingPolicy.OccupancyMs(snapPtr(herd)), routingPolicy.OccupancyMs(snapPtr(lowBurst)))
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
